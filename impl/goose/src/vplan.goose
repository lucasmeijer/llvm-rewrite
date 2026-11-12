// VPlan core: the data model (blocks, values, recipes as rows of global tables), VPValue/VPUser/VPDef operations,
// recipe list operations, VPBlockUtils, CFG traversals, plan creation / archiving / duplication, VPBuilder and the
// VPDominatorTree. Ported from llvm/lib/Transforms/Vectorize/VPlan.h, VPlanValue.h, VPlan.cpp (block / value /
// plan parts), VPlanCFG.h, VPlanUtils.h (VPBlockUtils), LoopVectorizationPlanner.h (VPBuilder) and
// VPlanDominatorTree.h. Design: DESIGN.md §17.
//
// One plan is "loaded" in the working tables at a time (vpb / vpv / vpr / the xv list pool / vph, the plan's own
// scalars). Other plans live in the archive (vp_save / vp_load copy a plan out and in, keeping every id), so
// VPlan::duplicate() is "load the source, then save as a new slot" plus the user-list rebuild of remapOperands.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import gen_iids;
import pm;
import scev;
import loopinfo;
import iv_descriptors;

fn vp_unported(what: const u8[:]) { fatal(str("loop-vectorize: ", what, " is not supported yet")); }

// ---------------------------------------------------------------------------------------------
// xv: growable i32 lists (SmallVector) as records in xvr with runs in xvd; copied to the end when they grow

struct XV { at: i32, n: i32, cap: i32 }
var xvr: XV[>..<];
var xvd: i32[>..<];
fn xv_new() -> i32 { xvr.push(XV { at: 0, n: 0, cap: 0 }); return (xvr.len - 1) as i32; }
fn xv_len(h: i32) -> i64 { xvr[h].n as i64 }
fn xv_get(h: i32, k: i64) -> i32 { xvd[(xvr[h].at as i64) + k] }
fn xv_set(h: i32, k: i64, v: i32) { xvd[(xvr[h].at as i64) + k] = v; }
fn xv_back(h: i32) -> i32 { xv_get(h, xv_len(h) - 1) }
fn xv_clear(h: i32) { xvr[h].n = 0; }
fn xv_reserve(h: i32, need: i64) {
    let cap = xvr[h].cap as i64;
    if need <= cap { return; }
    var ncap = cap * 2;
    if ncap < 4 { ncap = 4; }
    while ncap < need { ncap *= 2; }
    let nat = xvd.len;
    let at = xvr[h].at as i64;
    let n = xvr[h].n as i64;
    for k in n { let e = xvd[at + k]; xvd.push(e); }
    for k in ncap - n { xvd.push(-1); }
    xvr[h].at = nat as i32;
    xvr[h].cap = ncap as i32;
}
fn xv_push(h: i32, v: i32) {
    let n = xv_len(h);
    xv_reserve(h, n + 1);
    xvd[(xvr[h].at as i64) + n] = v;
    xvr[h].n = (n + 1) as i32;
}
fn xv_pop(h: i32) -> i32 { let v = xv_back(h); xvr[h].n -= 1; return v; }
fn xv_find(h: i32, v: i32) -> i64 { for k in xv_len(h) { if xv_get(h, k) == v { return k; } } return -1; }
fn xv_contains(h: i32, v: i32) -> bool { xv_find(h, v) >= 0 }
// erase(index), keeping order
fn xv_erase(h: i32, k: i64) {
    let n = xv_len(h);
    for j in k + 1..n { xv_set(h, j - 1, xv_get(h, j)); }
    xvr[h].n = (n - 1) as i32;
}
fn xv_insert(h: i32, at: i64, v: i32) {
    let n = xv_len(h);
    xv_reserve(h, n + 1);
    xvr[h].n = (n + 1) as i32;
    var k = n - 1;
    while k >= at { xv_set(h, k + 1, xv_get(h, k)); k--; }
    xv_set(h, at, v);
}
fn xv_copy_from(h: i32, src: i32) { xv_clear(h); for k in xv_len(src) { xv_push(h, xv_get(src, k)); } }
fn xv_to(h: i32, out: i32[>..<]&) { out.clear(); for k in xv_len(h) { out.push(xv_get(h, k)); } }
fn xv_from(vs: const i32[:]) -> i32 { let h = xv_new(); for v in vs { xv_push(h, v); } return h; }

// ---------------------------------------------------------------------------------------------
// kinds

let VPB_REGION: u8 = 0; let VPB_BASIC: u8 = 1; let VPB_IR_BASIC: u8 = 2;

// VPRecipeBase::VPRecipeTy, in LLVM's order
let VPR_BRANCH_ON_MASK: u8 = 0; let VPR_DERIVED_IV: u8 = 1; let VPR_EXPAND_SCEV: u8 = 2; let VPR_EXPRESSION: u8 = 3;
let VPR_IR_INSTRUCTION: u8 = 4; let VPR_INSTRUCTION: u8 = 5; let VPR_INTERLEAVE_EVL: u8 = 6; let VPR_INTERLEAVE: u8 = 7;
let VPR_REDUCTION_EVL: u8 = 8; let VPR_REDUCTION: u8 = 9; let VPR_REPLICATE: u8 = 10; let VPR_SCALAR_IV_STEPS: u8 = 11;
let VPR_VECTOR_POINTER: u8 = 12; let VPR_VECTOR_END_POINTER: u8 = 13; let VPR_WIDEN_CALL: u8 = 14;
let VPR_WIDEN_CANONICAL_IV: u8 = 15; let VPR_WIDEN_CAST: u8 = 16; let VPR_WIDEN_GEP: u8 = 17; let VPR_WIDEN_INTRINSIC: u8 = 18;
let VPR_WIDEN_MEM_INTRINSIC: u8 = 19; let VPR_WIDEN_LOAD_EVL: u8 = 20; let VPR_WIDEN_LOAD: u8 = 21;
let VPR_WIDEN_STORE_EVL: u8 = 22; let VPR_WIDEN_STORE: u8 = 23; let VPR_WIDEN: u8 = 24; let VPR_BLEND: u8 = 25;
let VPR_HISTOGRAM: u8 = 26; let VPR_WIDEN_PHI: u8 = 27; let VPR_PRED_INST_PHI: u8 = 28; let VPR_CURRENT_ITERATION_PHI: u8 = 29;
let VPR_ACTIVE_LANE_MASK_PHI: u8 = 30; let VPR_FIRST_ORDER_RECURRENCE_PHI: u8 = 31;
let VPR_WIDEN_INT_OR_FP_INDUCTION: u8 = 32; let VPR_WIDEN_POINTER_INDUCTION: u8 = 33; let VPR_REDUCTION_PHI: u8 = 34;
let VPR_FIRST_PHI: u8 = 27; let VPR_FIRST_HEADER_PHI: u8 = 29; let VPR_LAST_PHI: u8 = 34;

// VPInstruction opcodes beyond the IR opcodes (Instruction::OtherOpsEnd + 1, ...)
let VPI_FIRST_ORDER_RECURRENCE_SPLICE: i32 = 1000; let VPI_NOT: i32 = 1001; let VPI_ACTIVE_LANE_MASK: i32 = 1002;
let VPI_EXPLICIT_VECTOR_LENGTH: i32 = 1003; let VPI_INCOMING_ALIAS_MASK: i32 = 1004;
let VPI_CALCULATE_TRIP_COUNT_MINUS_VF: i32 = 1005; let VPI_CANONICAL_IV_INCREMENT_FOR_PART: i32 = 1006;
let VPI_BRANCH_ON_COUNT: i32 = 1007; let VPI_BRANCH_ON_COND: i32 = 1008; let VPI_BRANCH_ON_TWO_CONDS: i32 = 1009;
let VPI_BROADCAST: i32 = 1010; let VPI_BUILD_STRUCT_VECTOR: i32 = 1011; let VPI_BUILD_VECTOR: i32 = 1012;
let VPI_UNPACK: i32 = 1013; let VPI_COMPUTE_REDUCTION_RESULT: i32 = 1014; let VPI_EXTRACT_LAST_PART: i32 = 1015;
let VPI_EXTRACT_LAST_LANE: i32 = 1016; let VPI_EXTRACT_PENULTIMATE_ELEMENT: i32 = 1017; let VPI_LOGICAL_AND: i32 = 1018;
let VPI_LOGICAL_OR: i32 = 1019; let VPI_NUM_ACTIVE_LANES: i32 = 1020; let VPI_PTR_ADD: i32 = 1021;
let VPI_WIDE_PTR_ADD: i32 = 1022; let VPI_ANY_OF: i32 = 1023; let VPI_FIRST_ACTIVE_LANE: i32 = 1024;
let VPI_LAST_ACTIVE_LANE: i32 = 1025; let VPI_REVERSE: i32 = 1026; let VPI_REDUCTION_START_VECTOR: i32 = 1027;
let VPI_EXTRACT_LANE: i32 = 1028; let VPI_RESUME_FOR_EPILOGUE: i32 = 1029; let VPI_EXTRACT_LAST_ACTIVE: i32 = 1030;
let VPI_EXITING_IV_VALUE: i32 = 1031; let VPI_MASKED_COND: i32 = 1032; let VPI_WIDE_IV_STEP: i32 = 1033;
let VPI_STEP_VECTOR: i32 = 1034; let VPI_INTRINSIC: i32 = 1035;
fn vpi_is_ir_opcode(o: i32) -> bool { o < 1000 }

// VPIRFlags::OperationType
let VOT_CMP: u8 = 0; let VOT_FCMP: u8 = 1; let VOT_OVERFLOWING: u8 = 2; let VOT_TRUNC: u8 = 3; let VOT_DISJOINT: u8 = 4;
let VOT_EXACT: u8 = 5; let VOT_GEP: u8 = 6; let VOT_FMF: u8 = 7; let VOT_NNEG: u8 = 8; let VOT_REDUCTION: u8 = 9;
let VOT_OTHER: u8 = 10;
// VPIRFlags as a fixed record (the union's members side by side)
struct VPF { ot: u8, nuw: bool, nsw: bool, disjoint: bool, exact: bool, nneg: bool, gep: u8, fmf: u8, pred: u8,
             rk: i32, ordered: bool, inloop: bool }
fn vpf_none() -> VPF { VPF { ot: VOT_OTHER, nuw: false, nsw: false, disjoint: false, exact: false, nneg: false, gep: 0, fmf: 0, pred: 0, rk: 0, ordered: false, inloop: false } }
fn vpf_wrap(nuw: bool, nsw: bool) -> VPF { var f = vpf_none(); f.ot = VOT_OVERFLOWING; f.nuw = nuw; f.nsw = nsw; return f; }
fn vpf_trunc(nuw: bool, nsw: bool) -> VPF { var f = vpf_none(); f.ot = VOT_TRUNC; f.nuw = nuw; f.nsw = nsw; return f; }
fn vpf_cmp(p: i64) -> VPF { var f = vpf_none(); f.ot = VOT_CMP; f.pred = p as u8; return f; }
fn vpf_fcmp(p: i64, fmf: u8) -> VPF { var f = vpf_none(); f.ot = VOT_FCMP; f.pred = p as u8; f.fmf = fmf; return f; }
fn vpf_fmf(fmf: u8) -> VPF { var f = vpf_none(); f.ot = VOT_FMF; f.fmf = fmf; return f; }
fn vpf_disjoint(d: bool) -> VPF { var f = vpf_none(); f.ot = VOT_DISJOINT; f.disjoint = d; return f; }
fn vpf_nneg(n: bool) -> VPF { var f = vpf_none(); f.ot = VOT_NNEG; f.nneg = n; return f; }
fn vpf_exact(e: bool) -> VPF { var f = vpf_none(); f.ot = VOT_EXACT; f.exact = e; return f; }
fn vpf_gep(g: u8) -> VPF { var f = vpf_none(); f.ot = VOT_GEP; f.gep = g; return f; }
fn vpf_reduction(k: i32, ordered: bool, inloop: bool, fmf: u8) -> VPF {
    var f = vpf_none(); f.ot = VOT_REDUCTION; f.rk = k; f.ordered = ordered; f.inloop = inloop; f.fmf = fmf; return f;
}

// Reduction styles (RdxUnordered / RdxInLoop / RdxOrdered)
let VRS_UNORDERED: u8 = 0; let VRS_IN_LOOP: u8 = 1; let VRS_ORDERED: u8 = 2;

// value kinds
let VVK_IR: u8 = 0; let VVK_SYMBOLIC: u8 = 1; let VVK_REGION: u8 = 2; let VVK_SINGLE_DEF: u8 = 3; let VVK_MULTI_DEF: u8 = 4;

struct VPB {
    kind: u8, dead: bool, can_iv_nuw: bool,
    name: i32,            // string id
    parent: i32,          // VPRegionBlock *Parent
    preds: i32, succs: i32,   // xv lists
    first: i32, last: i32,    // recipe list (basic blocks)
    irbb: i32,            // VPIRBasicBlock
    entry: i32, exiting: i32, // regions
    can_iv: i32,          // VPCanonicalIVInfo (-1: a replicate region)
    header_mask: i32
}
struct VPV {
    kind: u8, materialized: bool,
    uv: i32,              // UnderlyingVal
    ty: i32,              // scalar type
    users: i32,           // xv list (SmallVector: push_back on addOperand, erase first match on removeUser)
    def: i32,             // defining recipe
    region: i32, dl: i32
}
struct VPR {
    kind: u8, dead: bool, with_type: bool, may_read: bool, may_write: bool, may_se: bool, single_scalar: bool,
    predicated: bool, consecutive: bool, masked: bool, gaps: bool, outside: bool, conditional: bool,
    rdx_style: u8, ind_kind: u8, expr_type: u8,
    parent: i32, prev: i32, next: i32,
    ops: i32,             // xv
    def: i32,             // single-def recipes
    defs: i32,            // xv (multi-def recipes), -1 when none
    md: i32,              // xv of (kind, node) pairs, -1 when none
    dl: i32,
    opcode: i32,          // INSTRUCTION, WIDEN, WIDEN_CAST, REPLICATE (the IR opcode), HISTOGRAM
    f: VPF,
    name: i32,            // INSTRUCTION, WIDEN_PHI (string id, -1 = none)
    ir_inst: i32,         // IR_INSTRUCTION; WIDEN mem: the ingredient; WIDEN_INT_OR_FP_INDUCTION: the trunc; INTERLEAVE: insert pos
    iid: i32,             // WIDEN_INTRINSIC, WIDEN_MEM_INTRINSIC
    src_elt_ty: i32,      // WIDEN_GEP, VECTOR_POINTER, VECTOR_END_POINTER
    stride: i64,          // VECTOR_END_POINTER
    ind: i32,             // WIDEN_*INDUCTION: induction descriptor id (ind_descs)
    fp_binop: i32,        // DERIVED_IV
    ind_opcode: i64,      // SCALAR_IV_STEPS (InductionOpcode)
    rdx_kind: i32,        // REDUCTION_PHI, REDUCTION
    rdx_scale: i32,       // REDUCTION_PHI: VFScaleFactor
    align: i64,           // memory recipes
    ig: i32,              // INTERLEAVE: group
    expr: i32,            // EXPAND_SCEV: the SCEV
    variant: i32,         // WIDEN_CALL: the vector function
    expr_recipes: i32     // EXPRESSION: xv
}

var vpb: VPB[>..<];
var vpv: VPV[>..<];
var vpr: VPR[>..<];

// the loaded plan's own scalars (VPlan members)
struct VPH {
    entry: i32, scalar_header: i32, exit_blocks: i32, vfs: i32, ufs: i32, name: i32,
    trip_count: i32, btc: i32, vtc: i32, vf: i32, uf: i32, vfxuf: i32,
    live_in_order: i32,   // xv of IR values, insertion order (SmallMapVector)
    created_blocks: i32
}
var vph: VPH;
var vp_live_map = hm_new();   // IR value -> VPValue (rebuilt on load)

// ---------------------------------------------------------------------------------------------
// the archive

struct VPSlot { b_at: i32, b_n: i32, v_at: i32, v_n: i32, r_at: i32, r_n: i32, xr_at: i32, xr_n: i32, xd_at: i32, xd_n: i32, h: VPH }
var vpa_slots: VPSlot[>..<];
var vpa_b: VPB[>..<];
var vpa_v: VPV[>..<];
var vpa_r: VPR[>..<];
var vpa_xr: XV[>..<];
var vpa_xd: i32[>..<];
var vp_cur_slot: i32 = -1;    // the slot the working tables were loaded from (-1 = a new plan)

fn vp_reset() {
    vpb.clear(); vpv.clear(); vpr.clear(); xvr.clear(); xvd.clear(); hm_clear(vp_live_map);
    vpa_slots.clear(); vpa_b.clear(); vpa_v.clear(); vpa_r.clear(); vpa_xr.clear(); vpa_xd.clear();
    vp_cur_slot = -1;
}
// save the loaded plan as a new archive slot
fn vp_save() -> i32 {
    var s = VPSlot { b_at: vpa_b.len as i32, b_n: vpb.len as i32, v_at: vpa_v.len as i32, v_n: vpv.len as i32,
                     r_at: vpa_r.len as i32, r_n: vpr.len as i32, xr_at: vpa_xr.len as i32, xr_n: xvr.len as i32,
                     xd_at: vpa_xd.len as i32, xd_n: xvd.len as i32, h: vph };
    for x in vpb { vpa_b.push(x); }
    for x in vpv { vpa_v.push(x); }
    for x in vpr { vpa_r.push(x); }
    for x in xvr { vpa_xr.push(x); }
    for x in xvd { vpa_xd.push(x); }
    vpa_slots.push(s);
    return (vpa_slots.len - 1) as i32;
}
// overwrite slot `k` with the loaded plan (appends new runs; the old ones are garbage)
fn vp_save_to(k: i32) { let n = vp_save(); vpa_slots[k] = vpa_slots[n]; vpa_slots.pop(); }
fn vp_load(k: i32) {
    let s = vpa_slots[k];
    vpb.clear(); vpv.clear(); vpr.clear(); xvr.clear(); xvd.clear();
    for j in s.b_n as i64 { vpb.push(vpa_b[(s.b_at as i64) + j]); }
    for j in s.v_n as i64 { vpv.push(vpa_v[(s.v_at as i64) + j]); }
    for j in s.r_n as i64 { vpr.push(vpa_r[(s.r_at as i64) + j]); }
    for j in s.xr_n as i64 { xvr.push(vpa_xr[(s.xr_at as i64) + j]); }
    for j in s.xd_n as i64 { xvd.push(vpa_xd[(s.xd_at as i64) + j]); }
    vph = s.h;
    hm_clear(vp_live_map);
    for j in xv_len(vph.live_in_order) {
        let v = xv_get(vph.live_in_order, j);
        // the live-in VPValue of v: the first IR value row with that underlying value
        for x in vpv.len { if vpv[x].kind == VVK_IR && vpv[x].uv == v { hm_put(vp_live_map, v as u64, x); break; } }
    }
    vp_cur_slot = k;
}

// VPlan::duplicate(): load `src`; the user lists are rebuilt in remapOperands' order (deep RPO over the blocks,
// recipes in order, operands in order). The caller works on the loaded copy and saves it as a new slot.
fn vp_duplicate_load(src: i32) {
    vp_load(src);
    vp_cur_slot = -1;
    // the copies of the lists must not alias the source's runs once they grow: they are fresh in the working pool
    for x in vpv.len { if vpv[x].users >= 0 { xv_clear(vpv[x].users); } }
    var rpo: i32[>..<] = [];
    vp_rpo(vph.entry, true, rpo);
    for b in rpo {
        if vpb[b].kind == VPB_REGION { continue; }
        var r = vpb[b].first;
        while r >= 0 {
            for k in xv_len(vpr[r].ops) { xv_push(vpv[xv_get(vpr[r].ops, k)].users, r); }
            r = vpr[r].next;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// values

fn vp_new_value(kind: u8, ty: i32, uv: i32) -> i32 {
    vpv.push(VPV { kind: kind, materialized: false, uv: uv, ty: ty, users: xv_new(), def: -1, region: -1, dl: -1 });
    return (vpv.len - 1) as i32;
}
fn vp_new_symbolic(ty: i32) -> i32 { vp_new_value(VVK_SYMBOLIC, ty, -1) }
// VPlan::getOrAddLiveIn
fn vp_live_in(v: i32) -> i32 {
    let x = hm_get(vp_live_map, v as u64, -1);
    if x >= 0 { return x as i32; }
    let nv = vp_new_value(VVK_IR, vals[v].ty as i32, v);
    hm_put(vp_live_map, v as u64, nv as i64);
    xv_push(vph.live_in_order, v);
    return nv;
}
fn vp_get_live_in(v: i32) -> i32 { hm_get(vp_live_map, v as u64, -1) as i32 }
fn vp_const_int(ty: i32, x: u64) -> i32 { vp_live_in(c_int(ty, x as! i64)) }
fn vp_true() -> i32 { vp_const_int(ty_int(1), 1) }
fn vp_false() -> i32 { vp_const_int(ty_int(1), 0) }
fn vp_poison(ty: i32) -> i32 { vp_live_in(c_poison(ty)) }

fn vp_is_ir_value(v: i32) -> bool { vpv[v].kind == VVK_IR }
fn vp_is_symbolic(v: i32) -> bool { let k = vpv[v].kind; k == VVK_SYMBOLIC || k == VVK_REGION }
fn vp_ir(v: i32) -> i32 { vpv[v].uv }
fn vp_uv(v: i32) -> i32 { vpv[v].uv }
fn vp_is_constant(v: i32) -> bool { vp_is_ir_value(v) && is_constant(vp_ir(v)) }
fn vp_is_constant_int(v: i32) -> bool { vp_is_ir_value(v) && vals[vp_ir(v)].kind == VK_CINT }
fn vp_is_const_int_zero(v: i32) -> bool { vp_is_constant_int(v) && cint_is_zero(vp_ir(v)) }
fn vp_is_const_int_one(v: i32) -> bool { vp_is_constant_int(v) && ap_is_one_vp(vp_ir(v)) }
fn ap_is_one_vp(c: i32) -> bool { let a = ci_ap(c); a.lo == 1 && (a.w <= 64 || ap_is_one_vp_wide(c)) }
fn ap_is_one_vp_wide(c: i32) -> bool { vp_unported("wide constants in VPlan"); return false; }
// VPValue::getScalarType
fn vp_scalar_type(v: i32) -> i32 { if vpv[v].kind == VVK_IR { vals[vpv[v].uv].ty as i32 } else { vpv[v].ty } }
// getDefiningRecipe
fn vp_def(v: i32) -> i32 {
    if v < 0 { return -1; }
    let k = vpv[v].kind;
    if k == VVK_SINGLE_DEF || k == VVK_MULTI_DEF { return vpv[v].def; }
    return -1;
}
fn vp_num_users(v: i32) -> i64 { xv_len(vpv[v].users) }
fn vp_user(v: i32, k: i64) -> i32 { xv_get(vpv[v].users, k) }
fn vp_has_one_use(v: i32) -> bool { vp_num_users(v) == 1 }
fn vp_single_user(v: i32) -> i32 { if vp_num_users(v) == 1 { vp_user(v, 0) } else { -1 } }
// hasMoreThanOneUniqueUser
fn vp_has_more_than_one_unique_user(v: i32) -> bool {
    let n = vp_num_users(v);
    if n == 0 { return false; }
    let u0 = vp_user(v, 0);
    for k in 1..n { if vp_user(v, k) != u0 { return true; } }
    return false;
}
fn vp_add_user(v: i32, r: i32) { xv_push(vpv[v].users, r); }
fn vp_remove_user(v: i32, r: i32) { let k = xv_find(vpv[v].users, r); if k >= 0 { xv_erase(vpv[v].users, k); } }
fn vp_users(v: i32, out: i32[>..<]&) { xv_to(vpv[v].users, out); }

// recipes: operands
fn vp_op(r: i32, k: i64) -> i32 { xv_get(vpr[r].ops, k) }
fn vp_nops(r: i32) -> i64 { xv_len(vpr[r].ops) }
fn vp_add_operand(r: i32, v: i32) { xv_push(vpr[r].ops, v); vp_add_user(v, r); }
fn vp_set_operand(r: i32, k: i64, v: i32) {
    let old = vp_op(r, k);
    vp_remove_user(old, r);
    xv_set(vpr[r].ops, k, v);
    vp_add_user(v, r);
}
fn vp_remove_operand(r: i32, k: i64) { vp_remove_user(vp_op(r, k), r); xv_erase(vpr[r].ops, k); }
fn vp_swap_operands(r: i32) { let a = vp_op(r, 0); xv_set(vpr[r].ops, 0, vp_op(r, 1)); xv_set(vpr[r].ops, 1, a); }

// VPValue::replaceUsesWithIf with a predicate F(user, operand index)
fn vp_replace_uses_with_if<F>(old: i32, nw: i32) {
    if old == nw { return; }
    var j: i64 = 0;
    while j < vp_num_users(old) {
        let r = vp_user(old, j);
        var removed = false;
        for i in vp_nops(r) {
            if vp_op(r, i) != old || !F(r, i) { continue; }
            removed = true;
            vp_set_operand(r, i, nw);
        }
        if !removed { j++; }
    }
}
// VPValue::replaceAllUsesWith
fn vp_rauw(old: i32, nw: i32) {
    vp_replace_uses_with_if(old, nw) { r, i => true };
    if vp_is_symbolic(old) { vpv[old].materialized = true; }
}
fn vp_replace_uses_of_with(r: i32, from: i32, to: i32) {
    for i in vp_nops(r) { if vp_op(r, i) == from { vp_set_operand(r, i, to); } }
}

fn vp_new_recipe(kind: u8, ops: const i32[:], dl: i32) -> i32 {
    vpr.push(VPR { kind: kind, dead: false, with_type: false, may_read: false, may_write: false, may_se: false,
                   single_scalar: false, predicated: false, consecutive: false, masked: false, gaps: false,
                   outside: false, conditional: false, rdx_style: 0, ind_kind: 0, expr_type: 0,
                   parent: -1, prev: -1, next: -1, ops: xv_new(), def: -1, defs: -1, md: -1, dl: dl, opcode: 0,
                   f: vpf_none(), name: -1, ir_inst: -1, iid: 0, src_elt_ty: -1, stride: 0, ind: -1, fp_binop: -1,
                   ind_opcode: -1, rdx_kind: 0, rdx_scale: 1, align: 0, ig: -1, expr: -1, variant: -1, expr_recipes: -1 });
    let r = (vpr.len - 1) as i32;
    for v in ops { vp_add_operand(r, v); }
    return r;
}
fn vp_new_single_def(kind: u8, ops: const i32[:], ty: i32, uv: i32, dl: i32) -> i32 {
    let r = vp_new_recipe(kind, ops, dl);
    let v = vp_new_value(VVK_SINGLE_DEF, ty, uv);
    vpv[v].def = r;
    vpr[r].def = v;
    return r;
}
fn vp_add_multi_def_value(r: i32, uv: i32, ty: i32) -> i32 {
    let v = vp_new_value(VVK_MULTI_DEF, ty, uv);
    vpv[v].def = r;
    if vpr[r].defs < 0 { vpr[r].defs = xv_new(); }
    xv_push(vpr[r].defs, v);
    return v;
}
fn vp_set_underlying(v: i32, uv: i32) { vpv[v].uv = uv; }
fn vp_val(r: i32) -> i32 { vpr[r].def }    // getVPSingleValue
fn vp_underlying_instr(r: i32) -> i32 { vpv[vpr[r].def].uv }
fn vp_num_defined_values(r: i32) -> i64 { if vpr[r].def >= 0 { 1 } else if vpr[r].defs >= 0 { xv_len(vpr[r].defs) } else { 0 } }
fn vp_defined_value(r: i32, k: i64) -> i32 { if vpr[r].def >= 0 { vpr[r].def } else { xv_get(vpr[r].defs, k) } }

// metadata (VPIRMetadata)
fn vp_md_set(r: i32, kind: i32, node: i32) {
    if vpr[r].md < 0 { vpr[r].md = xv_new(); }
    let h = vpr[r].md;
    var k: i64 = 0;
    while k < xv_len(h) { if xv_get(h, k) == kind { xv_set(h, k + 1, node); return; } k += 2; }
    xv_push(h, kind);
    xv_push(h, node);
}
fn vp_md_get(r: i32, kind: i32) -> i32 {
    let h = vpr[r].md;
    if h < 0 { return -1; }
    var k: i64 = 0;
    while k < xv_len(h) { if xv_get(h, k) == kind { return xv_get(h, k + 1); } k += 2; }
    return -1;
}
fn vp_md_copy(dst: i32, src: i32) {
    let h = vpr[src].md;
    if h < 0 { return; }
    var k: i64 = 0;
    while k < xv_len(h) { vp_md_set(dst, xv_get(h, k), xv_get(h, k + 1)); k += 2; }
}

fn vp_is_phi_kind(k: u8) -> bool { k >= VPR_FIRST_PHI && k <= VPR_LAST_PHI }
fn vp_is_header_phi_kind(k: u8) -> bool { k >= VPR_FIRST_HEADER_PHI && k <= VPR_LAST_PHI }
fn vp_is_header_phi(r: i32) -> bool { r >= 0 && vp_is_header_phi_kind(vpr[r].kind) }
fn vp_is_widen_memory_kind(k: u8) -> bool { k == VPR_WIDEN_LOAD || k == VPR_WIDEN_LOAD_EVL || k == VPR_WIDEN_STORE || k == VPR_WIDEN_STORE_EVL }
fn vp_is_widen_induction_kind(k: u8) -> bool { k == VPR_WIDEN_INT_OR_FP_INDUCTION || k == VPR_WIDEN_POINTER_INDUCTION }
fn vp_is_vpi(r: i32, opc: i32) -> bool { r >= 0 && vpr[r].kind == VPR_INSTRUCTION && vpr[r].opcode == opc }
fn vp_val_is_vpi(v: i32, opc: i32) -> bool { vp_is_vpi(vp_def(v), opc) }
fn vp_is_vp_phi(r: i32) -> bool { vp_is_vpi(r, OP_PHI as i32) }
fn vp_is_ir_phi(r: i32) -> bool { r >= 0 && vpr[r].kind == VPR_IR_INSTRUCTION && iop(vpr[r].ir_inst) == OP_PHI }
// VPRecipeBase::isPhi
fn vp_is_phi_recipe(r: i32) -> bool { vp_is_phi_kind(vpr[r].kind) || vp_is_vp_phi(r) || vp_is_ir_phi(r) }
// VPInstructionWithType::classof
fn vp_is_instruction_with_type(r: i32) -> bool {
    if r < 0 || vpr[r].kind != VPR_INSTRUCTION { return false; }
    let o = vpr[r].opcode;
    if vpi_is_ir_opcode(o) && is_cast_op(o as i64) { return true; }
    return o == VPI_WIDE_IV_STEP || o == VPI_STEP_VECTOR || o == VPI_INTRINSIC || o == OP_LOAD as i32;
}

// ---------------------------------------------------------------------------------------------
// recipe lists (iplist<VPRecipeBase>)

// VPBasicBlock::insert(Recipe, InsertPt); before = -1: end()
fn vp_insert_recipe(r: i32, b: i32, before: i32) {
    if vpr[r].parent >= 0 { fatal("internal: recipe already in a VPlan block"); }
    vpr[r].parent = b;
    if before < 0 {
        vpr[r].prev = vpb[b].last; vpr[r].next = -1;
        if vpb[b].last >= 0 { vpr[vpb[b].last].next = r; } else { vpb[b].first = r; }
        vpb[b].last = r;
    } else {
        let p = vpr[before].prev;
        vpr[r].prev = p; vpr[r].next = before;
        vpr[before].prev = r;
        if p >= 0 { vpr[p].next = r; } else { vpb[b].first = r; }
    }
}
fn vp_append_recipe(b: i32, r: i32) { vp_insert_recipe(r, b, -1); }
fn vp_insert_before(r: i32, pos: i32) { vp_insert_recipe(r, vpr[pos].parent, pos); }
fn vp_insert_after(r: i32, pos: i32) { vp_insert_recipe(r, vpr[pos].parent, vpr[pos].next); }
fn vp_remove_from_parent(r: i32) {
    let b = vpr[r].parent;
    let p = vpr[r].prev;
    let n = vpr[r].next;
    if p >= 0 { vpr[p].next = n; } else { vpb[b].first = n; }
    if n >= 0 { vpr[n].prev = p; } else { vpb[b].last = p; }
    vpr[r].parent = -1; vpr[r].prev = -1; vpr[r].next = -1;
}
fn vp_move_before(r: i32, b: i32, before: i32) { vp_remove_from_parent(r); vp_insert_recipe(r, b, before); }
fn vp_move_after(r: i32, pos: i32) { vp_remove_from_parent(r); vp_insert_after(r, pos); }
// VPRecipeBase::eraseFromParent
fn vp_erase_recipe(r: i32) {
    if vpr[r].parent >= 0 { vp_remove_from_parent(r); }
    vp_delete_recipe(r);
}
fn vp_delete_recipe(r: i32) {
    for k in vp_nops(r) { vp_remove_user(vp_op(r, k), r); }
    xv_clear(vpr[r].ops);
    if vpr[r].def >= 0 {
        if vp_num_users(vpr[r].def) != 0 { fatal("internal: deleting a VPValue with remaining users"); }
        vpv[vpr[r].def].def = -1;
    }
    if vpr[r].defs >= 0 { for k in xv_len(vpr[r].defs) { vpv[xv_get(vpr[r].defs, k)].def = -1; } }
    vpr[r].dead = true;
}
// a snapshot of the block's recipes (make_early_inc_range)
fn vp_block_recipes(b: i32, out: i32[>..<]&) {
    out.clear();
    var r = vpb[b].first;
    while r >= 0 { out.push(r); r = vpr[r].next; }
}
fn vp_block_empty(b: i32) -> bool { vpb[b].first < 0 }
// getFirstNonPhi (-1 = end())
fn vp_first_non_phi(b: i32) -> i32 {
    var r = vpb[b].first;
    while r >= 0 && vp_is_phi_recipe(r) { r = vpr[r].next; }
    return r;
}
fn vp_block_phis(b: i32, out: i32[>..<]&) {
    out.clear();
    var r = vpb[b].first;
    while r >= 0 && vp_is_phi_recipe(r) { out.push(r); r = vpr[r].next; }
}

// ---------------------------------------------------------------------------------------------
// blocks

fn vp_new_block(kind: u8, name: i32) -> i32 {
    vpb.push(VPB { kind: kind, dead: false, can_iv_nuw: true, name: name, parent: -1, preds: xv_new(), succs: xv_new(),
                   first: -1, last: -1, irbb: -1, entry: -1, exiting: -1, can_iv: -1, header_mask: -1 });
    let b = (vpb.len - 1) as i32;
    xv_push(vph.created_blocks, b);
    return b;
}
// VPlan::createVPBasicBlock
fn vp_create_basic_block(name: const u8[:]) -> i32 { vp_new_block(VPB_BASIC, intern(name)) }
// VPlan::createEmptyVPIRBasicBlock
fn vp_create_empty_ir_basic_block(irbb: i32) -> i32 {
    var nm: u8[>..] = [];
    nm.append("ir-bb<");
    nm.append(val_name(irbb));
    nm.append(">");
    let b = vp_new_block(VPB_IR_BASIC, intern(nm));
    vpb[b].irbb = irbb;
    return b;
}
// VPlan::createVPIRBasicBlock: a VPIRInstruction for every instruction but the terminator
fn vp_create_ir_basic_block(irbb: i32) -> i32 {
    let b = vp_create_empty_ir_basic_block(irbb);
    let t = block_terminator(irbb);
    var i = block_first(irbb);
    while i >= 0 && i != t { vp_append_recipe(b, vp_new_ir_instruction(i)); i = inst_next(i); }
    return b;
}
fn vp_new_ir_instruction(i: i32) -> i32 { let r = vp_new_recipe(VPR_IR_INSTRUCTION, [], -1); vpr[r].ir_inst = i; return r; }
// VPlan::createLoopRegion
fn vp_create_loop_region(can_iv_ty: i32, dl: i32, entry: i32, exiting: i32) -> i32 {
    let b = vp_new_block(VPB_REGION, intern(""));
    vp_region_init(b, entry, exiting);
    let cv = vp_new_value(VVK_REGION, can_iv_ty, -1);
    vpv[cv].region = b;
    vpv[cv].dl = dl;
    vpb[b].can_iv = cv;
    return b;
}
// VPlan::createReplicateRegion
fn vp_create_replicate_region(entry: i32, exiting: i32, name: const u8[:]) -> i32 {
    let b = vp_new_block(VPB_REGION, intern(name));
    vp_region_init(b, entry, exiting);
    return b;
}
fn vp_region_init(b: i32, entry: i32, exiting: i32) {
    vpb[b].entry = entry; vpb[b].exiting = exiting;
    if entry >= 0 { vpb[entry].parent = b; vpb[exiting].parent = b; }
}
fn vp_is_region(b: i32) -> bool { b >= 0 && vpb[b].kind == VPB_REGION }
fn vp_is_basic(b: i32) -> bool { b >= 0 && vpb[b].kind != VPB_REGION }
fn vp_is_ir_basic(b: i32) -> bool { b >= 0 && vpb[b].kind == VPB_IR_BASIC }
fn vp_is_replicator(b: i32) -> bool { vpb[b].can_iv < 0 }
fn vp_region_set_entry(r: i32, e: i32) { vpb[r].entry = e; vpb[e].parent = r; }
fn vp_region_set_exiting(r: i32, e: i32) { vpb[r].exiting = e; vpb[e].parent = r; }
fn vp_nsuccs(b: i32) -> i64 { xv_len(vpb[b].succs) }
fn vp_npreds(b: i32) -> i64 { xv_len(vpb[b].preds) }
fn vp_succ(b: i32, k: i64) -> i32 { xv_get(vpb[b].succs, k) }
fn vp_pred(b: i32, k: i64) -> i32 { xv_get(vpb[b].preds, k) }
fn vp_single_succ(b: i32) -> i32 { if vp_nsuccs(b) == 1 { vp_succ(b, 0) } else { -1 } }
fn vp_single_pred(b: i32) -> i32 { if vp_npreds(b) == 1 { vp_pred(b, 0) } else { -1 } }
fn vp_swap_succs(b: i32) { let h = vpb[b].succs; let t = xv_get(h, 0); xv_set(h, 0, xv_get(h, 1)); xv_set(h, 1, t); }
fn vp_swap_preds(b: i32) { let h = vpb[b].preds; let t = xv_get(h, 0); xv_set(h, 0, xv_get(h, 1)); xv_set(h, 1, t); }
fn vp_remove_succ(b: i32, s: i32) { let i = xv_find(vpb[b].succs, s); if i < 0 { fatal("internal: VPlan successor not found"); } xv_erase(vpb[b].succs, i); }
fn vp_remove_pred(b: i32, p: i32) { let i = xv_find(vpb[b].preds, p); if i < 0 { fatal("internal: VPlan predecessor not found"); } xv_erase(vpb[b].preds, i); }
fn vp_replace_pred(b: i32, old: i32, nw: i32) { let i = xv_find(vpb[b].preds, old); if i < 0 { fatal("internal: VPlan predecessor not found"); } xv_set(vpb[b].preds, i, nw); }
fn vp_replace_succ(b: i32, old: i32, nw: i32) { let i = xv_find(vpb[b].succs, old); if i < 0 { fatal("internal: VPlan successor not found"); } xv_set(vpb[b].succs, i, nw); }

// getEntryBasicBlock / getExitingBasicBlock
fn vp_entry_basic_block(b0: i32) -> i32 { var b = b0; while vp_is_region(b) { b = vpb[b].entry; } return b; }
fn vp_exiting_basic_block(b0: i32) -> i32 { var b = b0; while vp_is_region(b) { b = vpb[b].exiting; } return b; }
// getEnclosingBlockWithSuccessors / ...Predecessors
fn vp_enclosing_block_with_succs(b0: i32) -> i32 {
    var b = b0;
    while vp_nsuccs(b) == 0 && vpb[b].parent >= 0 { b = vpb[b].parent; }
    return b;
}
fn vp_enclosing_block_with_preds(b0: i32) -> i32 {
    var b = b0;
    while vp_npreds(b) == 0 && vpb[b].parent >= 0 { b = vpb[b].parent; }
    return b;
}
fn vp_single_hierarchical_pred(b: i32) -> i32 { vp_single_pred(vp_enclosing_block_with_preds(b)) }
fn vp_single_hierarchical_succ(b: i32) -> i32 { vp_single_succ(vp_enclosing_block_with_succs(b)) }
// VPBasicBlock::getEnclosingLoopRegion
fn vp_enclosing_loop_region(b: i32) -> i32 {
    var p = vpb[b].parent;
    if p >= 0 && vp_is_replicator(p) { p = vpb[p].parent; }
    return p;
}
fn vp_recipe_region(r: i32) -> i32 { vpb[vpr[r].parent].parent }
fn vp_is_exiting(b: i32) -> bool { let p = vpb[b].parent; p >= 0 && vp_exiting_basic_block(p) == b }
// VPBasicBlock::getTerminator
fn vp_terminator(b: i32) -> i32 {
    if vp_block_empty(b) { return -1; }
    if vp_nsuccs(b) >= 2 || (vp_is_exiting(b) && !vp_is_replicator(vpb[b].parent)) { return vpb[b].last; }
    return -1;
}
// VPBasicBlock::getCFGPredecessor
fn vp_cfg_predecessor(b: i32, idx: i64) -> i32 {
    var pred: i32 = -1;
    if vp_npreds(b) > 0 { pred = vp_pred(b, idx); }
    else {
        let region = vpb[b].parent;
        pred = if idx == 0 { vp_single_pred(region) } else { region };
    }
    return vp_exiting_basic_block(pred);
}

// VPBlockUtils
fn vpbu_connect(from: i32, to: i32) { xv_push(vpb[from].succs, to); xv_push(vpb[to].preds, from); }
fn vpbu_connect_at(from: i32, to: i32, pred_idx: i64, succ_idx: i64) {
    if succ_idx < 0 { xv_push(vpb[from].succs, to); } else { xv_set(vpb[from].succs, succ_idx, to); }
    if pred_idx < 0 { xv_push(vpb[to].preds, from); } else { xv_set(vpb[to].preds, pred_idx, from); }
}
fn vpbu_disconnect(from: i32, to: i32) { vp_remove_succ(from, to); vp_remove_pred(to, from); }
fn vpbu_transfer_successors(old: i32, nw: i32) {
    for k in vp_nsuccs(old) { vp_replace_pred(vp_succ(old, k), old, nw); }
    if vp_nsuccs(nw) != 0 { fatal("internal: VPlan successors already set"); }
    for k in vp_nsuccs(old) { xv_push(vpb[nw].succs, vp_succ(old, k)); }
    xv_clear(vpb[old].succs);
}
fn vpbu_insert_block_after(nw: i32, ptr: i32) {
    vpb[nw].parent = vpb[ptr].parent;
    vpbu_transfer_successors(ptr, nw);
    vpbu_connect(ptr, nw);
}
fn vpbu_insert_block_before(nw: i32, ptr: i32) {
    vpb[nw].parent = vpb[ptr].parent;
    var ps: i32[>..<] = [];
    xv_to(vpb[ptr].preds, ps);
    for p in ps { vp_replace_succ(p, ptr, nw); xv_push(vpb[nw].preds, p); }
    xv_clear(vpb[ptr].preds);
    vpbu_connect(nw, ptr);
}
fn vpbu_insert_two_blocks_after(if_true: i32, if_false: i32, ptr: i32) {
    xv_push(vpb[ptr].succs, if_true); xv_push(vpb[ptr].succs, if_false);
    xv_push(vpb[if_true].preds, ptr); xv_push(vpb[if_false].preds, ptr);
    vpb[if_true].parent = vpb[ptr].parent; vpb[if_false].parent = vpb[ptr].parent;
}
fn vpbu_insert_on_edge(from: i32, to: i32, ptr: i32) {
    let si = xv_find(vpb[from].succs, to);
    let pi = xv_find(vpb[to].preds, from);
    vpbu_connect_at(from, ptr, -1, si);
    vpbu_connect_at(ptr, to, pi, -1);
}

// ---------------------------------------------------------------------------------------------
// traversals (VPlanCFG.h)

// children in the hierarchical ("deep") graph: a region's child is its entry; a block without successors continues
// with the successors of its innermost enclosing block that has some
fn vp_children(b: i32, deep: bool, out: i32[>..<]&) {
    out.clear();
    if !deep { xv_to(vpb[b].succs, out); return; }
    if vp_is_region(b) { if vpb[b].entry >= 0 { out.push(vpb[b].entry); } return; }
    var c = b;
    while c >= 0 && vp_nsuccs(c) == 0 { c = vpb[c].parent; }
    if c < 0 { return; }
    xv_to(vpb[c].succs, out);
}
// depth_first (preorder) over the deep or shallow graph
fn vp_depth_first(start: i32, deep: bool, out: i32[>..<]&) {
    out.clear();
    var visited = hm_new();
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    var kids: i32[>..<] = [];
    hm_put(visited, start as u64, 1);
    out.push(start);
    st_b.push(start); st_k.push(0);
    while st_b.len > 0 {
        let t = st_b.len - 1;
        vp_children(st_b[t], deep, kids);
        let k = st_k[t];
        if k >= kids.len { st_b.pop(); st_k.pop(); continue; }
        st_k[t] = k + 1;
        let c = kids[k];
        if hm_has(visited, c as u64) { continue; }
        hm_put(visited, c as u64, 1);
        out.push(c);
        st_b.push(c); st_k.push(0);
    }
}
// ReversePostOrderTraversal over the deep or shallow graph
fn vp_rpo(start: i32, deep: bool, out: i32[>..<]&) {
    out.clear();
    var post: i32[>..<] = [];
    var visited = hm_new();
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    var kids: i32[>..<] = [];
    hm_put(visited, start as u64, 1);
    st_b.push(start); st_k.push(0);
    while st_b.len > 0 {
        let t = st_b.len - 1;
        vp_children(st_b[t], deep, kids);
        let k = st_k[t];
        if k >= kids.len { post.push(st_b[t]); st_b.pop(); st_k.pop(); continue; }
        st_k[t] = k + 1;
        let c = kids[k];
        if hm_has(visited, c as u64) { continue; }
        hm_put(visited, c as u64, 1);
        st_b.push(c); st_k.push(0);
    }
    var k = post.len - 1;
    while k >= 0 { out.push(post[k]); k--; }
}
fn vp_only_basic(xs: i32[>..<]&) {
    var j: i64 = 0;
    for k in xs.len { if vp_is_basic(xs[k]) { xs[j] = xs[k]; j++; } }
    xs.resize(j);
}
fn vp_only_regions(xs: i32[>..<]&) {
    var j: i64 = 0;
    for k in xs.len { if vp_is_region(xs[k]) { xs[j] = xs[k]; j++; } }
    xs.resize(j);
}
// all VPBasicBlocks in deep depth-first order from the plan entry
fn vp_all_basic_blocks_deep(out: i32[>..<]&) { vp_depth_first(vph.entry, true, out); vp_only_basic(out); }

// ---------------------------------------------------------------------------------------------
// VPlan accessors

// getVectorLoopRegion: the first region in a shallow depth-first walk from the entry
fn vp_vector_loop_region() -> i32 {
    var xs: i32[>..<] = [];
    vp_depth_first(vph.entry, false, xs);
    for b in xs { if vp_is_region(b) { return b; } }
    return -1;
}
fn vp_vector_preheader() -> i32 { let r = vp_vector_loop_region(); if r < 0 { -1 } else { vp_single_pred(r) } }
fn vp_middle_block() -> i32 { let r = vp_vector_loop_region(); return vp_succ(r, vp_nsuccs(r) - 1); }
fn vp_scalar_preheader() -> i32 {
    let p = vp_single_pred(vph.scalar_header);
    if p < 0 || !vp_is_basic(p) { return -1; }
    return p;
}
fn vp_is_exit_block(b: i32) -> bool { xv_contains(vph.exit_blocks, b) }
fn vp_has_vf(vf: i64) -> bool { xv_contains(vph.vfs, vf as i32) }
fn vp_add_vf(vf: i64) { if !vp_has_vf(vf) { xv_push(vph.vfs, vf as i32); } }
fn vp_set_vf(vf: i64) { xv_clear(vph.vfs); xv_push(vph.vfs, vf as i32); }
fn vp_single_vf() -> i64 { if xv_len(vph.vfs) != 1 { fatal("internal: VPlan has more than one VF"); } return xv_get(vph.vfs, 0) as i64; }
fn vp_has_scalar_vf_only() -> bool { xv_len(vph.vfs) == 1 && xv_get(vph.vfs, 0) == 1 }
fn vp_has_uf(uf: i64) -> bool { if xv_len(vph.ufs) == 0 { return true; } return xv_contains(vph.ufs, uf as i32); }
fn vp_set_uf(uf: i64) { xv_clear(vph.ufs); xv_push(vph.ufs, uf as i32); }
fn vp_is_unrolled() -> bool { xv_len(vph.ufs) == 1 }
fn vp_index_type() -> i32 { vpv[vph.vf].ty }
fn vp_or_create_backedge_taken_count() -> i32 {
    if vph.btc < 0 { vph.btc = vp_new_symbolic(vpv[vph.vtc].ty); }
    return vph.btc;
}
// hasEarlyExit
fn vp_has_early_exit() -> bool {
    var n: i64 = 0;
    for k in xv_len(vph.exit_blocks) { n += vp_npreds(xv_get(vph.exit_blocks, k)); }
    let sph = vp_scalar_preheader();
    let sphp = if sph >= 0 { vp_single_pred(sph) } else { -1 };
    if sphp >= 0 && vp_nsuccs(sphp) == 1 { return n >= 1; }
    return n > 1;
}
// hasScalarTail
fn vp_has_scalar_tail() -> bool {
    let sph = vp_scalar_preheader();
    return sph >= 0 && xv_contains(vpb[sph].preds, vp_middle_block());
}
fn vp_has_tail_folded() -> bool { let r = vp_vector_loop_region(); r >= 0 && vpb[r].header_mask >= 0 }

// getUniqueExitBlocks
fn vp_unique_exit_blocks(l: i32, out: i32[>..<]&) {
    out.clear();
    var seen = hm_new();
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        for j in block_nsucc(bb) {
            let s = block_succ(bb, j);
            if !loop_contains(l, s) && !hm_has(seen, s as u64) { hm_put(seen, s as u64, 1); out.push(s); }
        }
    }
}

// VPlan::VPlan(Loop *L, Type *IdxTy): a fresh plan in the (cleared) working tables
fn vp_plan_new(l: i32, idx_ty: i32) {
    vpb.clear(); vpv.clear(); vpr.clear(); xvr.clear(); xvd.clear(); hm_clear(vp_live_map);
    vp_cur_slot = -1;
    vph = VPH { entry: -1, scalar_header: -1, exit_blocks: xv_new(), vfs: xv_new(), ufs: xv_new(), name: intern(""),
                trip_count: -1, btc: -1, vtc: -1, vf: -1, uf: -1, vfxuf: -1, live_in_order: xv_new(), created_blocks: xv_new() };
    vph.vtc = vp_new_symbolic(idx_ty);
    vph.vf = vp_new_symbolic(idx_ty);
    vph.uf = vp_new_symbolic(idx_ty);
    vph.vfxuf = vp_new_symbolic(idx_ty);
    vph.entry = vp_create_ir_basic_block(loop_preheader(l));
    vph.scalar_header = vp_create_ir_basic_block(loop_header(l));
    var exits: i32[>..<] = [];
    vp_unique_exit_blocks(l, exits);
    for e in exits { xv_push(vph.exit_blocks, vp_create_ir_basic_block(e)); }
}

// ---------------------------------------------------------------------------------------------
// VPDominatorTree (dominance queries only), over the hierarchical CFG from the plan entry

var vpdt_order = hm_new();   // block -> RPO number
var vpdt_idom = hm_new();    // block -> idom
fn vp_dt_build() {
    hm_clear(vpdt_order);
    hm_clear(vpdt_idom);
    var rpo: i32[>..<] = [];
    vp_rpo(vph.entry, true, rpo);
    for k in rpo.len { hm_put(vpdt_order, rpo[k] as u64, k); }
    // predecessors in the deep graph, in RPO-of-predecessor order
    var pfrom: i32[>..<] = [];
    var pto: i32[>..<] = [];
    var kids: i32[>..<] = [];
    for b in rpo {
        vp_children(b, true, kids);
        for c in kids { pfrom.push(b); pto.push(c); }
    }
    hm_put(vpdt_idom, vph.entry as u64, vph.entry as i64);
    var changed = true;
    while changed {
        changed = false;
        for b in rpo {
            if b == vph.entry { continue; }
            var nidom: i32 = -1;
            for e in pto.len {
                if pto[e] != b { continue; }
                let p = pfrom[e];
                if !hm_has(vpdt_idom, p as u64) { continue; }
                if nidom < 0 { nidom = p; continue; }
                var a = p;
                var c = nidom;
                while a != c {
                    var oa = hm_get(vpdt_order, a as u64, 0);
                    var oc = hm_get(vpdt_order, c as u64, 0);
                    while oa > oc { a = hm_get(vpdt_idom, a as u64, 0) as i32; oa = hm_get(vpdt_order, a as u64, 0); }
                    while oc > oa { c = hm_get(vpdt_idom, c as u64, 0) as i32; oc = hm_get(vpdt_order, c as u64, 0); }
                }
                nidom = a;
            }
            let cur = hm_get(vpdt_idom, b as u64, -1);
            if nidom >= 0 && cur != nidom as i64 { hm_put(vpdt_idom, b as u64, nidom as i64); changed = true; }
        }
    }
}
fn vp_dt_dominates(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if !hm_has(vpdt_order, b as u64) { return true; }
    if !hm_has(vpdt_order, a as u64) { return false; }
    var x = b;
    while true {
        let i = hm_get(vpdt_idom, x as u64, -1) as i32;
        if i == x || i < 0 { return false; }
        if i == a { return true; }
        x = i;
    }
    return false;
}
// properlyDominates(const VPRecipeBase *A, const VPRecipeBase *B)
fn vp_dt_properly_dominates(a: i32, b: i32) -> bool {
    if a == b { return false; }
    let pa = vpr[a].parent;
    let pb = vpr[b].parent;
    if pa == pb {
        var x = vpr[a].next;
        while x >= 0 { if x == b { return true; } x = vpr[x].next; }
        return false;
    }
    var ra = pa;
    var rb = pb;
    if vpb[ra].parent >= 0 && vp_is_replicator(vpb[ra].parent) { ra = vpb[ra].parent; }
    if vpb[rb].parent >= 0 && vp_is_replicator(vpb[rb].parent) { rb = vpb[rb].parent; }
    return vp_dt_dominates(ra, rb);
}

// ---------------------------------------------------------------------------------------------
// VPBuilder: an insertion point (block, before-recipe; -1 = end of the block)

var vpbld_bb: i32 = -1;
var vpbld_ip: i32 = -1;
fn vpb_set_at_end(b: i32) { vpbld_bb = b; vpbld_ip = -1; }
fn vpb_set_at(b: i32, ip: i32) { vpbld_bb = b; vpbld_ip = ip; }
fn vpb_set_before(r: i32) { vpbld_bb = vpr[r].parent; vpbld_ip = r; }
fn vpb_set_after(r: i32) { vpbld_bb = vpr[r].parent; vpbld_ip = vpr[r].next; }
fn vpb_insert(r: i32) -> i32 { if vpbld_bb >= 0 { vp_insert_recipe(r, vpbld_bb, vpbld_ip); } return r; }

// VPInstruction constructor
fn vp_new_instruction(opcode: i32, ops: const i32[:], f: VPF, dl: i32, name: const u8[:], result_ty: i32) -> i32 {
    var ty = result_ty;
    if ty < 0 { ty = vp_compute_scalar_type_for_instruction(opcode, ops); }
    let r = vp_new_single_def(VPR_INSTRUCTION, ops, ty, -1, dl);
    vpr[r].opcode = opcode;
    vpr[r].f = f;
    vpr[r].name = if name.len > 0 { intern(name) } else { -1 };
    return r;
}
fn vpb_nary(opcode: i32, ops: const i32[:], f: VPF, dl: i32, name: const u8[:], result_ty: i32) -> i32 {
    return vpb_insert(vp_new_instruction(opcode, ops, f, dl, name, result_ty));
}
fn vpb_nary0(opcode: i32, ops: const i32[:]) -> i32 { vpb_nary(opcode, ops, vp_default_flags(opcode, -1), -1, "", -1) }
fn vpb_add(l: i32, r: i32, dl: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 { vpb_nary(OP_ADD as i32, [l, r], vpf_wrap(nuw, nsw), dl, name, -1) }
fn vpb_sub(l: i32, r: i32, dl: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 { vpb_nary(OP_SUB as i32, [l, r], vpf_wrap(nuw, nsw), dl, name, -1) }
fn vpb_not(v: i32, dl: i32, name: const u8[:]) -> i32 { vpb_nary(VPI_NOT, [v], vpf_none(), dl, name, -1) }
fn vpb_icmp(p: i64, l: i32, r: i32, dl: i32, name: const u8[:]) -> i32 { vpb_nary(OP_ICMP as i32, [l, r], vpf_cmp(p), dl, name, -1) }
// createScalarPhi (VPPhi)
fn vpb_scalar_phi(incoming: const i32[:], dl: i32, name: const u8[:], f: VPF, result_ty: i32) -> i32 {
    var ty = result_ty;
    if ty < 0 && incoming.len > 0 { ty = vp_scalar_type(incoming[0]); }
    let r = vp_new_single_def(VPR_INSTRUCTION, incoming, ty, -1, dl);
    vpr[r].opcode = OP_PHI as i32;
    vpr[r].f = f;
    vpr[r].name = if name.len > 0 { intern(name) } else { -1 };
    return vpb_insert(r);
}
// createScalarCast (VPInstructionWithType); f.ot == VOT_OTHER = VPIRFlags::getDefaultFlags(Opcode)
fn vpb_scalar_cast(opc: i64, v: i32, ty: i32, dl: i32, f0: VPF) -> i32 {
    var f = f0;
    if f.ot == VOT_OTHER { f = vp_default_flags(opc as i32, ty); }
    let r = vp_new_instruction(opc as i32, [v], f, dl, "", ty);
    vpr[r].with_type = true;
    return vpb_insert(r);
}
// createScalarLoad
fn vpb_scalar_load(ty: i32, addr: i32, dl: i32) -> i32 {
    let r = vp_new_instruction(OP_LOAD as i32, [addr], vpf_none(), dl, "", ty);
    vpr[r].with_type = true;
    return vpb_insert(r);
}
// createScalarZExtOrTrunc / createScalarSExtOrTrunc
fn vpb_scalar_zext_or_trunc(v: i32, ty: i32, src_ty: i32, dl: i32) -> i32 {
    if ty == src_ty { return v; }
    let o = if ty_bits(ty_scalar(ty)) < ty_bits(ty_scalar(src_ty)) { OP_TRUNC } else { OP_ZEXT };
    return vp_val(vpb_scalar_cast(o, v, ty, dl, vp_default_flags(o as i32, -1)));
}
fn vpb_scalar_sext_or_trunc(v: i32, ty: i32, src_ty: i32, dl: i32) -> i32 {
    if ty == src_ty { return v; }
    let o = if ty_bits(ty_scalar(ty)) < ty_bits(ty_scalar(src_ty)) { OP_TRUNC } else { OP_SEXT };
    return vp_val(vpb_scalar_cast(o, v, ty, dl, vp_default_flags(o as i32, -1)));
}

// VPIRFlags::getDefaultFlags
fn vp_default_flags(opcode: i32, result_ty: i32) -> VPF {
    if opcode == VPI_CANONICAL_IV_INCREMENT_FOR_PART { return vpf_wrap(false, false); }
    if opcode == VPI_PTR_ADD || opcode == VPI_WIDE_PTR_ADD { return vpf_gep(0); }
    if opcode == VPI_COMPUTE_REDUCTION_RESULT { fatal("internal: opcode requires explicit flags"); }
    if !vpi_is_ir_opcode(opcode) { return vpf_none(); }
    let o = opcode as i64;
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL { return vpf_wrap(false, false); }
    if o == OP_TRUNC { return vpf_trunc(false, false); }
    if o == OP_OR { return vpf_disjoint(false); }
    if o == OP_ASHR || o == OP_LSHR || o == OP_UDIV || o == OP_SDIV { return vpf_exact(false); }
    if o == OP_GEP { return vpf_gep(0); }
    if o == OP_ZEXT || o == OP_UITOFP { return vpf_nneg(false); }
    if o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV || o == OP_FREM || o == OP_FNEG || o == OP_FPEXT || o == OP_FPTRUNC { return vpf_fmf(0); }
    if o == OP_SELECT { if result_ty >= 0 && ty_is_fp(ty_scalar(result_ty)) { return vpf_fmf(0); } return vpf_none(); }
    if o == OP_ICMP || o == OP_FCMP { fatal("internal: opcode requires explicit flags"); }
    return vpf_none();
}

// computeScalarTypeForInstruction (VPlanRecipes.cpp)
fn vp_compute_scalar_type_for_instruction(opcode: i32, ops: const i32[:]) -> i32 {
    if ops.len == 0 { fatal("internal: zero-operand VPInstruction opcodes must pass explicit ResultTy"); }
    let op0 = vp_scalar_type(ops[0]);
    if vpi_is_ir_opcode(opcode) {
        let o = opcode as i64;
        if o == OP_SWITCH || o == OP_STORE { return T_VOID as i32; }
        if o == OP_ICMP || o == OP_FCMP { return ty_int(1); }
        if o == OP_SELECT { return vp_scalar_type(ops[1]); }
        if o == OP_INSERTELEMENT { return op0; }
        if o == OP_EXTRACTVALUE { return ty_index(op0, cint_lo(vp_ir(ops[1])) as i64); }
        if o == OP_LOAD || o == OP_ALLOCA { fatal("internal: VPInstruction type must be passed explicitly"); }
        if o == OP_CALL {
            let f = vp_ir(ops[vp_called_fn_operand_index_ops(ops)]);
            return ty_fn_ret(globs[glob_of(f)].vty);
        }
        return op0;
    }
    if opcode == VPI_BRANCH_ON_COND || opcode == VPI_BRANCH_ON_TWO_CONDS || opcode == VPI_BRANCH_ON_COUNT { return T_VOID as i32; }
    if opcode == VPI_ACTIVE_LANE_MASK || opcode == VPI_MASKED_COND || opcode == VPI_LOGICAL_AND || opcode == VPI_LOGICAL_OR || opcode == VPI_ANY_OF { return ty_int(1); }
    if opcode == VPI_EXPLICIT_VECTOR_LENGTH { return ty_int(32); }
    if opcode == VPI_EXTRACT_LANE { return vp_scalar_type(ops[1]); }
    if opcode == VPI_FIRST_ACTIVE_LANE || opcode == VPI_LAST_ACTIVE_LANE || opcode == VPI_NUM_ACTIVE_LANES || opcode == VPI_INCOMING_ALIAS_MASK {
        fatal("internal: VPInstruction type must be passed explicitly");
    }
    return op0;
}
// getCalledFnOperandIndex: the called function is the last operand (unmasked) or the second to last (masked)
fn vp_called_fn_operand_index_ops(ops: const i32[:]) -> i64 {
    let n = ops.len;
    let last = ops[n - 1];
    if vp_is_ir_value(last) && vals[vp_ir(last)].kind == VK_FUNC { return n - 1; }
    return n - 2;
}
