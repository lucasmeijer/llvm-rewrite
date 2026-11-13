// VPTransformState and VPlan execution: VPlan::execute, VPBasicBlock / VPIRBasicBlock::execute
// (connectToPredecessors), VPTransformState::get / set, the IRBuilder<> (ConstantFolder) the recipes use, and every
// ported recipe's execute() as one match on the recipe kind. Ported from llvm/lib/Transforms/Vectorize/VPlan.cpp,
// VPlanHelpers.h and VPlanRecipes.cpp. Recipes whose execution is not ported yet fail loudly.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import datalayout;
import pm;
import apint;
import constfold;
import autoupgrade;
import domtree;
import dtu;
import loopinfo;
import loopsimplify;
import loop_utils;
import cfgutil;
import iv_descriptors;
import vplan;
import vplan_utils;
import vplan_props;

// ---------------------------------------------------------------------------------------------
// the IRBuilder<> (ConstantFolder) of the state

var vxb_bb: i32 = -1;
var vxb_pos: i32 = -1;       // insert before; -1 = end of vxb_bb
var vxb_dl: i32 = -1;        // current debug location
var vxb_fmf: u8 = 0;         // the builder's FastMathFlags

fn vxb_set_end(bb: i32) { vxb_bb = bb; vxb_pos = -1; }
fn vxb_set_before(i: i32) { vxb_bb = inst_parent(i); vxb_pos = i; }
fn vxb_insert(iv: i32, name: const u8[:]) -> i32 {
    inst_insert_at(iv, vxb_bb, vxb_pos, false);
    if vals[iv].ty as i32 != T_VOID && name.len > 0 { set_name(iv, name); }
    if vxb_dl >= 0 { inst_set_md(iv, 0, vxb_dl); }
    return iv;
}
// CreateBinOp (FMF of the builder on FP operations)
fn vxb_binop(o: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = if is_desirable_binop(o) { ce_binop(o, a, b, 0) } else { cf_binop(o, a, b) };
        if r >= 0 { return r; }
    }
    let i = create_inst(o, vals[a].ty as i32, [a, b]);
    if is_fp_math_operator(i) { insts[inst_of(i)].fmf = vxb_fmf; }
    return vxb_insert(i, name);
}
fn vxb_fneg(a: i32, name: const u8[:]) -> i32 {
    if is_constant(a) { let r = cf_fold_unary(OP_FNEG, a); if r >= 0 { return r; } }
    let i = create_inst(OP_FNEG, vals[a].ty as i32, [a]);
    insts[inst_of(i)].fmf = vxb_fmf;
    return vxb_insert(i, name);
}
fn vxb_cmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) { let r = cf_compare(p, a, b); if r >= 0 { return r; } }
    let o = if p < 32 { OP_FCMP } else { OP_ICMP };
    let i = create_inst(o, cmp_result_ty(vals[a].ty as i32), [a, b]);
    insts[inst_of(i)].pred = p as u8;
    if o == OP_FCMP { insts[inst_of(i)].fmf = vxb_fmf; }
    return vxb_insert(i, name);
}
fn vxb_select(c: i32, t: i32, f: i32, name: const u8[:]) -> i32 {
    if is_constant(c) && is_constant(t) && is_constant(f) { let r = cf_select(c, t, f); if r >= 0 { return r; } }
    let i = create_inst(OP_SELECT, vals[t].ty as i32, [c, t, f]);
    if is_fp_math_operator(i) { insts[inst_of(i)].fmf = vxb_fmf; }
    return vxb_insert(i, name);
}
fn vxb_cast(o: i64, v: i32, ty: i32, name: const u8[:]) -> i32 {
    if vals[v].ty as i32 == ty { return v; }
    if is_constant(v) { let r = ce_cast(o, v, ty); if r >= 0 { return r; } }
    let i = create_inst(o, ty, [v]);
    if is_fp_math_operator(i) { insts[inst_of(i)].fmf = vxb_fmf; }
    return vxb_insert(i, name);
}
fn vxb_extract(vec: i32, idx: i32, name: const u8[:]) -> i32 {
    if is_constant(vec) && is_constant(idx) { return ce_extractelement(vec, idx); }
    return vxb_insert(create_inst(OP_EXTRACTELEMENT, ty_elem(vals[vec].ty), [vec, idx]), name);
}
fn vxb_insert_elt(vec: i32, elt: i32, idx: i32, name: const u8[:]) -> i32 {
    if is_constant(vec) && is_constant(elt) && is_constant(idx) { return ce_insertelement(vec, elt, idx); }
    return vxb_insert(create_inst(OP_INSERTELEMENT, vals[vec].ty as i32, [vec, elt, idx]), name);
}
fn vxb_shuffle(v1: i32, v2: i32, mask: const i32[:], name: const u8[:]) -> i32 {
    let t1 = vals[v1].ty;
    let rt = ty_vector(ty_elem(t1), mask.len, ty_kind(t1) == TK_SVEC);
    if is_constant(v1) && is_constant(v2) {
        let r = ce_shufflevector(v1, v2, mask);
        if r >= 0 { return r; }
    }
    let s = create_inst(OP_SHUFFLEVECTOR, rt, [v1, v2]);
    let at = ints.len as i32;
    for m in mask { ints.push(m); }
    insts[inst_of(s)].aux = at;
    insts[inst_of(s)].naux = mask.len as i32;
    return vxb_insert(s, name);
}
// CreateVectorSplat(EC, V, Name)
fn vxb_splat(n: i64, v: i32, name: const u8[:]) -> i32 {
    let p = c_poison(ty_vector(vals[v].ty, n, false));
    var nm: u8[>..] = [];
    nm.append(name);
    nm.append(".splatinsert");
    let ins = vxb_insert_elt(p, v, c_int(T_I64, 0), nm);
    var zeros: i32[>..<] = [];
    for k in n { zeros.push(0); }
    var nm2: u8[>..] = [];
    nm2.append(name);
    nm2.append(".splat");
    return vxb_shuffle(ins, c_poison(vals[ins].ty as i32), zeros, nm2);
}
fn vxb_align_code(al: i64) -> u8 { if al <= 0 { 0 } else { (log2_exact(al) + 1) as u8 } }
fn vxb_load(ty: i32, p: i32, al: i64, name: const u8[:]) -> i32 {
    let li = create_inst(OP_LOAD, ty, [p]);
    insts[inst_of(li)].align = vxb_align_code(al);
    return vxb_insert(li, name);
}
fn vxb_store(v: i32, p: i32, al: i64) -> i32 {
    let si = create_inst(OP_STORE, T_VOID, [v, p]);
    insts[inst_of(si)].align = vxb_align_code(al);
    return vxb_insert(si, "");
}
// CreateGEP(Ty, Ptr, Idx, Name, NW)
fn vxb_gep(ty: i32, p: i32, idxs: const i32[:], name: const u8[:], flags: u8) -> i32 {
    var all_const = is_constant(p);
    for x in idxs { if !is_constant(x) { all_const = false; } }
    if all_const { vp_unported("constant-folded GEPs in vector code"); }
    var opsv: i32[>..<] = [];
    opsv.push(p);
    for x in idxs { opsv.push(x); }
    var rt = vals[p].ty as i32;
    for x in idxs { if ty_is_vector(vals[x].ty) && !ty_is_vector(rt) { rt = ty_vector(rt, ty_count(vals[x].ty), false); } }
    let g = create_inst(OP_GEP, rt, opsv);
    insts[inst_of(g)].ty2 = ty;
    insts[inst_of(g)].flags = flags;
    return vxb_insert(g, name);
}

// ---------------------------------------------------------------------------------------------
// VPTransformState

var vts_vf: i64 = 1;
var vts_vec = hm_new();         // VPV2Vector
var vts_lane = hm_new();        // VPV2Scalars: (value << 16 | lane) -> IR value
var vts_bb = hm_new();          // VPBB2IRBB
var vts_prev_bb: i32 = -1;
var vts_exit_bb: i32 = -1;
var vts_parent_loop: i32 = -1;
var vts_fv: i32 = -1;

fn vts_reset(vf: i64, fv: i32, parent_loop: i32) {
    vts_vf = vf;
    hm_clear(vts_vec); hm_clear(vts_lane); hm_clear(vts_bb);
    vts_prev_bb = -1; vts_exit_bb = -1;
    vts_parent_loop = parent_loop;
    vts_fv = fv;
    vxb_fmf = 0; vxb_dl = -1;
}
fn vts_key(d: i32, lane: i64) -> u64 { ((d as u64) << 16) | (lane as u64) }
fn vts_has_scalar(d: i32, lane: i64) -> bool { hm_has(vts_lane, vts_key(d, lane)) }
fn vts_set(d: i32, v: i32, is_scalar: bool) {
    if is_scalar { vts_set_lane(d, v, 0); return; }
    hm_put(vts_vec, d as u64, v as i64);
}
fn vts_set_lane(d: i32, v: i32, lane: i64) { hm_put(vts_lane, vts_key(d, lane), v as i64); }
fn vts_bb_of(b: i32) -> i32 { hm_get(vts_bb, b as u64, -1) as i32 }

// VPTransformState::get(Def, Lane)
recursive fn vts_get_lane(d: i32, lane: i64) -> i32 {
    let k = vpv[d].kind;
    if k == VVK_IR || k == VVK_SYMBOLIC || k == VVK_REGION {
        if vpv[d].uv < 0 { fatal("internal: symbolic VPValue used before it is materialized"); }
        return vpv[d].uv;
    }
    if vts_has_scalar(d, lane) { return hm_get(vts_lane, vts_key(d, lane), -1) as i32; }
    if lane != 0 && vp_is_single_scalar(d) && vts_has_scalar(d, 0) { return hm_get(vts_lane, vts_key(d, 0), -1) as i32; }
    if vp_val_is_vpi(d, VPI_BUILD_VECTOR) { return vts_get(vp_op(vp_def(d), lane), true); }
    let v = hm_get(vts_vec, d as u64, -1) as i32;
    if v < 0 { fatal("internal: VPValue has no generated value"); }
    if !ty_is_vector(vals[v].ty) {
        if lane != 0 { fatal("internal: cannot get lane > 0 of a scalar"); }
        return v;
    }
    return vxb_extract(v, c_int(T_I64, lane), "");
}
// VPTransformState::get(Def, NeedsScalar)
recursive fn vts_get(d: i32, needs_scalar: bool) -> i32 {
    if needs_scalar { return vts_get_lane(d, 0); }
    let x = hm_get(vts_vec, d as u64, -1);
    if x >= 0 { return x as i32; }
    let scalar = vts_get_lane(d, 0);
    let last = vts_get_lane(d, vts_vf - 1);
    let sbb = vxb_bb;
    let spos = vxb_pos;
    if is_inst(last) {
        // getInsertionPointAfterDef
        if iop(last) == OP_PHI { vxb_bb = inst_parent(last); vxb_pos = first_non_phi(vxb_bb); }
        else if iop(last) == OP_INVOKE { vp_unported("broadcasting an invoke result"); }
        else { vxb_bb = inst_parent(last); vxb_pos = inst_next(last); }
    }
    var vecv = scalar;
    if vts_vf > 1 { vecv = vxb_splat(vts_vf, scalar, "broadcast"); }
    vxb_bb = sbb;
    vxb_pos = spos;
    vts_set(d, vecv, false);
    return vecv;
}

// VPIRFlags::applyFlags
fn vp_apply_flags(r: i32, i: i32) {
    let f = vpr[r].f;
    let ii = inst_of(i);
    if f.ot == VOT_OVERFLOWING || f.ot == VOT_TRUNC {
        var fl = insts[ii].flags & ~(FL_NUW | FL_NSW);
        if f.nuw { fl = fl | FL_NUW; }
        if f.nsw { fl = fl | FL_NSW; }
        insts[ii].flags = fl;
    } else if f.ot == VOT_DISJOINT {
        insts[ii].flags = (insts[ii].flags & ~FL_DISJOINT) | (if f.disjoint { FL_DISJOINT } else { 0 });
    } else if f.ot == VOT_EXACT {
        insts[ii].flags = (insts[ii].flags & ~FL_EXACT) | (if f.exact { FL_EXACT } else { 0 });
    } else if f.ot == VOT_NNEG {
        insts[ii].flags = (insts[ii].flags & ~FL_NNEG) | (if f.nneg { FL_NNEG } else { 0 });
    } else if f.ot == VOT_GEP {
        insts[ii].flags = f.gep;
    } else if f.ot == VOT_FMF || f.ot == VOT_FCMP {
        insts[ii].fmf = f.fmf;
    } else if f.ot == VOT_REDUCTION {
        fatal("internal: reduction ops should not use applyFlags");
    }
}
// VPIRMetadata::applyMetadata
fn vp_apply_metadata(r: i32, i: i32) {
    let h = vpr[r].md;
    if h < 0 { return; }
    var k: i64 = 0;
    while k < xv_len(h) { inst_set_md(i, xv_get(h, k), xv_get(h, k + 1)); k += 2; }
}
fn vp_fmf_or_none(r: i32) -> u8 { let ot = vpr[r].f.ot; if ot == VOT_FMF || ot == VOT_FCMP || ot == VOT_REDUCTION { vpr[r].f.fmf } else { 0 } }
fn vp_name(r: i32) -> const u8[:] { if vpr[r].name >= 0 { sbytes(vpr[r].name) } else { "" } }

// ---------------------------------------------------------------------------------------------
// recipe execution

// executePhiRecipe (VPPhi / VPWidenPHIRecipe)
fn vts_execute_phi(r: i32, is_scalar: bool, name: const u8[:]) {
    let n = if vp_is_header_block(vpr[r].parent) { 1 } else { vp_phi_num_incoming(r) };
    let first = vts_get(vp_op(r, 0), is_scalar);
    let phi = vxb_insert(create_inst(OP_PHI, vals[first].ty as i32, []), name);
    phi_add_incoming(phi, first, vts_bb_of(vp_phi_incoming_block(r, 0)));
    for k in 1..n { phi_add_incoming(phi, vts_get(vp_op(r, k), is_scalar), vts_bb_of(vp_phi_incoming_block(r, k))); }
    vts_set(vpr[r].def, phi, is_scalar);
}
// VPBlockUtils::isHeader with the state's VPDT
fn vp_is_header_block(b: i32) -> bool {
    if !vp_is_basic(b) { return false; }
    let r = vpb[b].parent;
    if r >= 0 { return !vp_is_replicator(r) && vp_npreds(b) == 0; }
    return vp_npreds(b) == 2 && vp_dt_dominates(b, vp_pred(b, 1));
}
fn vp_is_latch_block(b: i32) -> bool { vp_nsuccs(b) >= 2 && vp_is_header_block(vp_succ(b, vp_nsuccs(b) - 1)) }

// VPInstruction::canGenerateScalarForFirstLane
fn vpi_can_generate_scalar_for_first_lane(r: i32) -> bool {
    let o = vpr[r].opcode;
    if vp_opcode_is_binary(o) || vp_opcode_is_cast(o) { return true; }
    if vpi_is_single_scalar(r) || vpi_is_vector_to_scalar(r) { return true; }
    return o == OP_FREEZE as i32 || o == OP_ICMP as i32 || o == OP_PHI as i32 || o == OP_SELECT as i32 || o == VPI_BRANCH_ON_COND ||
           o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_BRANCH_ON_COUNT || o == VPI_CALCULATE_TRIP_COUNT_MINUS_VF ||
           o == VPI_CANONICAL_IV_INCREMENT_FOR_PART || o == VPI_PTR_ADD || o == VPI_EXPLICIT_VECTOR_LENGTH || o == VPI_ANY_OF ||
           o == VPI_NOT;
}
fn vpi_has_result(r: i32) -> bool {
    let o = vpr[r].opcode;
    if o == VPI_BRANCH_ON_COND || o == VPI_BRANCH_ON_TWO_CONDS || o == VPI_BRANCH_ON_COUNT { return false; }
    if vpi_is_ir_opcode(o) {
        let io = o as i64;
        return !(io == OP_RET || io == OP_BR || io == OP_CONDBR || io == OP_STORE || io == OP_SWITCH || io == OP_INDIRECTBR ||
                 io == OP_RESUME || io == OP_CATCHRET || io == OP_UNREACHABLE || io == OP_FENCE || io == OP_ATOMICRMW);
    }
    return true;
}

// VPInstruction::generate
fn vpi_generate(r: i32) -> i32 {
    let o = vpr[r].opcode;
    let name = vp_name(r);
    if vp_opcode_is_binary(o) {
        let ofl = vp_only_first_lane_used(vpr[r].def);
        let a = vts_get(vp_op(r, 0), ofl);
        let b = vts_get(vp_op(r, 1), ofl);
        let res = vxb_binop(o as i64, a, b, name);
        if is_inst(res) { vp_apply_flags(r, res); }
        return res;
    }
    if o == VPI_NOT {
        let a = vts_get(vp_op(r, 0), vp_only_first_lane_used(vpr[r].def));
        return vxb_binop(OP_XOR, a, c_int(vals[a].ty as i32, -1), name);
    }
    if o == OP_ICMP as i32 || o == OP_FCMP as i32 {
        let ofl = vp_only_first_lane_used(vpr[r].def);
        let a = vts_get(vp_op(r, 0), ofl);
        let b = vts_get(vp_op(r, 1), ofl);
        return vxb_cmp(vpr[r].f.pred as i64, a, b, name);
    }
    if o == OP_SELECT as i32 {
        let ofl = vp_only_first_lane_used(vpr[r].def);
        let c = vts_get(vp_op(r, 0), ofl || vp_is_single_scalar(vp_op(r, 0)));
        let a = vts_get(vp_op(r, 1), ofl);
        let b = vts_get(vp_op(r, 2), ofl);
        let sfmf = vxb_fmf;
        vxb_fmf = vp_fmf_or_none(r);
        let s = vxb_select(c, a, b, name);
        vxb_fmf = sfmf;
        return s;
    }
    if o == OP_EXTRACTELEMENT as i32 {
        if vp_is_constant_int(vp_op(r, 1)) { return vts_get_lane(vp_op(r, 0), cint_lo(vp_ir(vp_op(r, 1))) as i64); }
        return vxb_extract(vts_get(vp_op(r, 0), false), vts_get(vp_op(r, 1), true), name);
    }
    if o == VPI_BRANCH_ON_COND {
        let cond = vts_get_lane(vp_op(r, 0), 0);
        let bb = vpr[r].parent;
        let second = vp_succ(bb, 1);
        let second_ir = vts_bb_of(second);
        let irbb = vts_bb_of(bb);
        let br = vxb_insert(create_inst(OP_CONDBR, T_VOID, [cond, irbb, second_ir]), "");
        term_set_succ(br, 0, -1);
        inst_erase_from_parent(block_terminator_before(irbb, br));
        vp_apply_metadata(r, br);
        return br;
    }
    if o == VPI_BROADCAST { return vxb_splat(vts_vf, vts_get(vp_op(r, 0), true), "broadcast"); }
    if o == VPI_BUILD_VECTOR {
        let sty = vp_scalar_type(vp_op(r, 0));
        var res = c_poison(ty_vector(sty, vp_nops(r), false));
        for k in vp_nops(r) { res = vxb_insert_elt(res, vts_get(vp_op(r, k), true), c_int(T_I32, k), ""); }
        return res;
    }
    if o == VPI_EXTRACT_LAST_LANE || o == VPI_EXTRACT_PENULTIMATE_ELEMENT {
        let off: i64 = if o == VPI_EXTRACT_PENULTIMATE_ELEMENT { 2 } else { 1 };
        var res: i32 = -1;
        if vts_vf > 1 { res = vts_get_lane(vp_op(r, 0), vts_vf - off); } else { res = vts_get(vp_op(r, 0), false); }
        if is_inst(res) && iop(res) == OP_EXTRACTELEMENT && name.len > 0 { set_name(res, name); }
        return res;
    }
    if o == VPI_REDUCTION_START_VECTOR {
        if vts_vf == 1 { return vts_get(vp_op(r, 0), true); }
        let scale = cint_lo(vp_ir(vp_op(r, 2))) as i64;
        let iden = vxb_splat(vts_vf / scale, vts_get(vp_op(r, 1), true), "");
        return vxb_insert_elt(iden, vts_get(vp_op(r, 0), true), c_int(T_I32, 0), name);
    }
    if o == VPI_COMPUTE_REDUCTION_RESULT {
        let f = vpr[r].f;
        let rk = f.rk;
        if rk_is_find_iv(rk) { fatal("internal: loop-vectorize: FindIV should use min/max reduction kinds"); }
        let n = vp_nops(r);
        var parts: i32[>..<] = [];
        for k in n { parts.push(vts_get(vp_op(r, k), f.inloop)); }
        var red = parts[0];
        if f.ordered { red = parts[n - 1]; }
        else {
            for k in 1..n {
                if rk_is_minmax(rk) { red = vxb_min_max_op(rk, red, parts[k]); }
                else {
                    var o2 = rk_opcode(rk);
                    if rk == RK_SUB { o2 = OP_ADD; } else if rk == RK_FSUB { o2 = OP_FADD; }
                    red = vxb_binop(o2, parts[k], red, "bin.rdx");
                }
            }
        }
        if vts_vf > 1 && !f.inloop { red = vxb_simple_reduction(red, rk); }
        return red;
    }
    if o == VPI_PTR_ADD {
        let p = vts_get_lane(vp_op(r, 0), 0);
        let a = vts_get_lane(vp_op(r, 1), 0);
        return vxb_gep(ty_int(8), p, [a], name, vpr[r].f.gep);
    }
    vp_unported(str("executing VPInstruction opcode ", o));
    return -1;
}
// CreateIntrinsic(RetTy, ID, Args) at the insert point (FMF of the builder on FP results)
fn vxb_intrinsic(id: i64, ov: const i32[:], args: const i32[:], name: const u8[:]) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in args { opsv.push(a); }
    opsv.push(f);
    let ci = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(ci)].ty2 = fty;
    if is_fp_math_operator(ci) { insts[inst_of(ci)].fmf = vxb_fmf; }
    return vxb_insert(ci, name);
}
// createMinMaxOp(Builder, RK, Left, Right)
fn vxb_min_max_op(rk: i32, l: i32, r: i32) -> i32 {
    let ty = vals[l].ty as i32;
    if ty_is_int(ty_scalar(ty)) || rk == RK_FMINNUM || rk == RK_FMAXNUM || rk == RK_FMINIMUM || rk == RK_FMAXIMUM ||
       rk == RK_FMINIMUMNUM || rk == RK_FMAXIMUMNUM {
        if is_constant(l) && is_constant(r) { vp_unported("constant-folding min/max intrinsics"); }
        return vxb_intrinsic(vxb_min_max_intrinsic(rk) as i64, [ty], [l, r], "rdx.minmax");
    }
    vp_unported("FP min/max reductions combined with compare and select");
    return -1;
}
// getMinMaxReductionIntrinsicOp(RecurKind)
fn vxb_min_max_intrinsic(rk: i32) -> i32 {
    if rk == RK_UMIN { return IID_umin; }
    if rk == RK_UMAX { return IID_umax; }
    if rk == RK_SMIN { return IID_smin; }
    if rk == RK_SMAX { return IID_smax; }
    if rk == RK_FMIN || rk == RK_FMINNUM { return IID_minnum; }
    if rk == RK_FMAX || rk == RK_FMAXNUM { return IID_maxnum; }
    if rk == RK_FMINIMUM { return IID_minimum; }
    if rk == RK_FMAXIMUM { return IID_maximum; }
    if rk == RK_FMINIMUMNUM { return IID_minimumnum; }
    if rk == RK_FMAXIMUMNUM { return IID_maximumnum; }
    fatal("internal: loop-vectorize: unknown min/max recurrence kind");
    return 0;
}
// getReductionIntrinsicID(RecurKind)
fn vxb_reduction_intrinsic(rk: i32) -> i32 {
    if rk == RK_ADD_CHAIN_WITH_SUBS || rk == RK_SUB || rk == RK_ADD { return IID_vector_reduce_add; }
    if rk == RK_MUL { return IID_vector_reduce_mul; }
    if rk == RK_AND { return IID_vector_reduce_and; }
    if rk == RK_OR { return IID_vector_reduce_or; }
    if rk == RK_XOR { return IID_vector_reduce_xor; }
    if rk == RK_FMULADD || rk == RK_FADD_CHAIN_WITH_SUBS || rk == RK_FSUB || rk == RK_FADD { return IID_vector_reduce_fadd; }
    if rk == RK_FMUL { return IID_vector_reduce_fmul; }
    if rk == RK_SMAX { return IID_vector_reduce_smax; }
    if rk == RK_SMIN { return IID_vector_reduce_smin; }
    if rk == RK_UMAX { return IID_vector_reduce_umax; }
    if rk == RK_UMIN { return IID_vector_reduce_umin; }
    if rk == RK_FMAX || rk == RK_FMAXNUM || rk == RK_FMAXIMUMNUM { return IID_vector_reduce_fmax; }
    if rk == RK_FMIN || rk == RK_FMINNUM || rk == RK_FMINIMUMNUM { return IID_vector_reduce_fmin; }
    if rk == RK_FMAXIMUM { return IID_vector_reduce_fmaximum; }
    if rk == RK_FMINIMUM { return IID_vector_reduce_fminimum; }
    fatal("internal: loop-vectorize: Unexpected recurrence kind");
    return 0;
}
// createSimpleReduction(Builder, Src, RdxKind)
fn vxb_simple_reduction(src: i32, rk: i32) -> i32 {
    let vty = vals[src].ty as i32;
    let elt = ty_elem(vty);
    let id = vxb_reduction_intrinsic(rk) as i64;
    if rk == RK_FMULADD || rk == RK_FADD_CHAIN_WITH_SUBS || rk == RK_FSUB || rk == RK_FADD || rk == RK_FMUL {
        var iden: i32 = -1;
        if rk == RK_FMUL { iden = binop_identity(OP_FMUL, elt, false); }
        else if (vxb_fmf & FMF_NSZ) != 0 { iden = c_null(elt); }
        else { iden = binop_identity(OP_FADD, elt, false); }
        return vxb_intrinsic(id, [vty], [iden, src], "");
    }
    if rk_is_any_of(rk) || rk_is_find(rk) { fatal("internal: loop-vectorize: Unhandled opcode in createSimpleReduction"); }
    if is_constant(src) { vp_unported("constant-folding reduction intrinsics"); }
    return vxb_intrinsic(id, [vty], [src], "");
}
// the terminator of irbb other than `except` (the temporary unreachable)
fn block_terminator_before(bb: i32, except: i32) -> i32 {
    let t = block_last(bb);
    if t == except { return inst_prev(except); }
    return t;
}

// VPInstruction::execute
fn vpi_execute(r: i32) {
    let o = vpr[r].opcode;
    let sfmf = vxb_fmf;
    vxb_fmf = vp_fmf_or_none(r);
    if o == OP_PHI as i32 { vts_execute_phi(r, true, vp_name(r)); vxb_fmf = sfmf; return; }
    if vp_is_instruction_with_type(r) { vpi_with_type_execute(r); vxb_fmf = sfmf; return; }
    let gv = vpi_generate(r);
    vxb_fmf = sfmf;
    if !vpi_has_result(r) { return; }
    let d = vpr[r].def;
    let per_first = vpi_can_generate_scalar_for_first_lane(r) && (vp_only_first_lane_used(d) || vpi_is_vector_to_scalar(r) || vpi_is_single_scalar(r));
    vts_set(d, gv, per_first);
    if o == VPI_RESUME_FOR_EPILOGUE || o == OP_FREEZE as i32 { vp_set_underlying(d, gv); }
}
// VPInstructionWithType::execute
fn vpi_with_type_execute(r: i32) {
    let rty = vpv[vpr[r].def].ty;
    let o = vpr[r].opcode;
    if vp_opcode_is_cast(o) {
        let a = vts_get_lane(vp_op(r, 0), 0);
        let c = vxb_cast(o as i64, a, rty, vp_name(r));
        if is_inst(c) && c != a { vp_apply_flags(r, c); vp_apply_metadata(r, c); }
        vts_set_lane(vpr[r].def, c, 0);
        return;
    }
    if o == VPI_STEP_VECTOR {
        let vty = ty_vector(rty, vts_vf, false);
        var elts: i32[>..<] = [];
        for i in vts_vf { elts.push(c_int(rty, i)); }
        vts_set(vpr[r].def, c_aggregate(vty, elts), false);
        return;
    }
    vp_unported(str("executing VPInstructionWithType opcode ", o));
}

// VPWidenRecipe::execute
fn vp_widen_execute(r: i32) {
    let o = vpr[r].opcode as i64;
    let d = vpr[r].def;
    if (o >= OP_ADD && o <= OP_XOR) || o == OP_FNEG {
        var ops: i32[>..<] = [];
        for k in vp_nops(r) { ops.push(vts_get(vp_op(r, k), false)); }
        var v: i32 = -1;
        if o == OP_FNEG { v = vxb_fneg(ops[0], ""); } else { v = vxb_binop(o, ops[0], ops[1], ""); }
        if is_inst(v) { vp_apply_flags(r, v); vp_apply_metadata(r, v); }
        vts_set(d, v, false);
        return;
    }
    if o == OP_ICMP || o == OP_FCMP {
        let a = vts_get(vp_op(r, 0), false);
        let b = vts_get(vp_op(r, 1), false);
        let c = vxb_cmp(vpr[r].f.pred as i64, a, b, "");
        if is_inst(c) { vp_apply_flags(r, c); vp_apply_metadata(r, c); }
        vts_set(d, c, false);
        return;
    }
    if o == OP_SELECT {
        let co = vp_op(r, 0);
        let c = vts_get(co, vp_is_single_scalar(co));
        let a = vts_get(vp_op(r, 1), false);
        let b = vts_get(vp_op(r, 2), false);
        let sel = vxb_select(c, a, b, "");
        vts_set(d, sel, false);
        if is_inst(sel) && iop(sel) == OP_SELECT {
            if is_fp_math_operator(sel) { vp_apply_flags(r, sel); }
            vp_apply_metadata(r, sel);
        }
        return;
    }
    if o == OP_FREEZE {
        let a = vts_get(vp_op(r, 0), false);
        vts_set(d, vxb_insert(create_inst(OP_FREEZE, vals[a].ty as i32, [a]), ""), false);
        return;
    }
    vp_unported(str("widening opcode ", o));
}

// VPScalarIVStepsRecipe::execute
fn vp_scalar_iv_steps_execute(r: i32) {
    let sfmf = vxb_fmf;
    vxb_fmf = vp_fmf_or_none(r);
    let base = vts_get_lane(vp_op(r, 0), 0);
    let step = vts_get_lane(vp_op(r, 1), 0);
    let bty = ty_scalar(vals[base].ty);
    if !ty_is_int(bty) { vp_unported("FP scalar IV steps"); }
    let first_only = vp_only_first_lane_used(vpr[r].def);
    let end_lane = if first_only { 1 } else { vts_vf };
    let si = if vp_nops(r) == 4 { vp_op(r, 3) } else { -1 };
    let start0 = if si >= 0 { vts_get(si, true) } else { c_int(bty, 0) };
    let bits = ty_bits(bty);
    for lane in end_lane {
        let lv = c_int(bty, lane);
        let start = vxb_binop(OP_ADD, start0, lv, "");
        let mul = vxb_binop(OP_MUL, start, step, "");
        let add = vxb_binop(OP_ADD, base, mul, "");
        vts_set_lane(vpr[r].def, add, lane);
    }
    let x = bits;
    vxb_fmf = sfmf;
}

// VPReplicateRecipe::execute (single-scalar after replicateByVF)
fn vp_replicate_execute(r: i32) {
    if !vpr[r].single_scalar { fatal("internal: VPReplicateRecipes must be unrolled before ::execute"); }
    let ui = vp_underlying_instr(r);
    let c = inst_clone(ui);
    let rty = vpv[vpr[r].def].ty;
    if rty != T_VOID && rty != vals[c].ty as i32 { vp_unported("replicating with a changed type"); }
    vp_apply_flags(r, c);
    vp_apply_metadata(r, c);
    let ot = vpr[r].f.ot;
    if ot == VOT_CMP || ot == VOT_FCMP { insts[inst_of(c)].pred = vpr[r].f.pred; }
    for k in vp_nops(r) { set_op(c, k, vts_get(vp_op(r, k), true)); }
    vxb_insert(c, "");
    vts_set(vpr[r].def, c, true);
    if iop(c) == OP_CALL && call_iid(c) == IID_assume { vp_unported("replicating llvm.assume"); }
}

fn vp_execute_recipe(r: i32) {
    let k = vpr[r].kind;
    if k == VPR_IR_INSTRUCTION {
        let i = vpr[r].ir_inst;
        if iop(i) == OP_PHI {
            for idx in vp_nops(r) {
                let o = vp_op(r, idx);
                let lane: i64 = if vp_is_single_scalar(o) { 0 } else { vts_vf - 1 };
                let pred = vp_pred(vpr[r].parent, idx);
                let pbb = vts_bb_of(vp_exiting_basic_block(pred));
                vxb_set_before(block_terminator(pbb));
                let v = vts_get_lane(o, lane);
                let pk = phi_block_index(i, pbb);
                if pk < 0 { phi_add_incoming(i, v, pbb); } else { set_op(i, pk, v); }
            }
        }
        let nx = inst_next(i);
        if nx >= 0 { vxb_bb = inst_parent(i); vxb_pos = nx; } else { vxb_set_end(inst_parent(i)); }
        return;
    }
    if k == VPR_INSTRUCTION { vpi_execute(r); return; }
    if k == VPR_WIDEN { vp_widen_execute(r); return; }
    if k == VPR_WIDEN_CAST {
        let dty = ty_vector(vpv[vpr[r].def].ty, vts_vf, false);
        let a = vts_get(vp_op(r, 0), false);
        let c = vxb_cast(vpr[r].opcode as i64, a, dty, "");
        vts_set(vpr[r].def, c, false);
        if is_inst(c) && c != a { vp_apply_flags(r, c); vp_apply_metadata(r, c); }
        return;
    }
    if k == VPR_WIDEN_GEP {
        var ops: i32[>..<] = [];
        for j in vp_nops(r) { let o = vp_op(r, j); ops.push(vts_get(o, vp_is_single_scalar(o))); }
        var idxs: i32[>..<] = [];
        for j in 1..ops.len { idxs.push(ops[j]); }
        let g = vxb_gep(vpr[r].src_elt_ty, ops[0], idxs, "wide.gep", vpr[r].f.gep);
        vts_set(vpr[r].def, g, vp_is_single_scalar(vpr[r].def));
        return;
    }
    if k == VPR_VECTOR_POINTER {
        if vp_nops(r) <= 2 { fatal("internal: Expected prior simplification of recipe without VFxPart"); }
        let p = vts_get_lane(vp_op(r, 0), 0);
        var off = vts_get(vp_op(r, 2), true);
        if !vpm_one(vp_op(r, 1)) { vp_unported("vector pointers with a non-unit stride"); }
        let g = vxb_gep(vpr[r].src_elt_ty, p, [off], "", vpr[r].f.gep);
        vts_set(vpr[r].def, g, true);
        return;
    }
    if k == VPR_SCALAR_IV_STEPS { vp_scalar_iv_steps_execute(r); return; }
    if k == VPR_REPLICATE { vp_replicate_execute(r); return; }
    if k == VPR_WIDEN_LOAD {
        let sty = vpv[vpr[r].def].ty;
        let dty = ty_vector(sty, vts_vf, false);
        if !vpr[r].consecutive || vpr[r].masked { vp_unported("gathers and masked loads"); }
        let addr = vts_get(vp_op(r, 0), true);
        let ld = vxb_load(dty, addr, vpr[r].align, "wide.load");
        vp_apply_metadata(r, ld);
        vts_set(vpr[r].def, ld, false);
        return;
    }
    if k == VPR_WIDEN_STORE {
        if !vpr[r].consecutive || vpr[r].masked { vp_unported("scatters and masked stores"); }
        let val = vts_get(vp_op(r, 1), false);
        let addr = vts_get(vp_op(r, 0), true);
        let st = vxb_store(val, addr, vpr[r].align);
        vp_apply_metadata(r, st);
        return;
    }
    if k == VPR_WIDEN_PHI { vts_execute_phi(r, false, vp_name(r)); return; }
    if k == VPR_REDUCTION_PHI {
        let in_loop = vpr[r].rdx_style != VRS_UNORDERED;
        let scalar_phi = vts_vf == 1 || in_loop;
        let vector_ph = vts_bb_of(vp_cfg_predecessor(vpr[r].parent, 0));
        let start = vts_get(vp_op(r, 0), scalar_phi);
        let header = vts_prev_bb;
        let phi = create_inst(OP_PHI, vals[start].ty as i32, []);
        inst_insert_at(phi, header, first_non_phi(header), false);
        set_name(phi, "vec.phi");
        vts_set(vpr[r].def, phi, in_loop);
        phi_add_incoming(phi, start, vector_ph);
        return;
    }
    vp_unported(str("executing recipe kind ", k));
}

// ---------------------------------------------------------------------------------------------
// blocks

// VPBasicBlock::connectToPredecessors
fn vts_connect_to_predecessors(vpbb: i32) {
    let new_bb = vts_bb_of(vpbb);
    var parent_loop = vts_parent_loop;
    var soe = vp_single_succ(vpbb);
    if soe < 0 { soe = vpbb; }
    if vp_is_exit_block(soe) { parent_loop = li_loop_for(vpb[soe].irbb); }
    if parent_loop >= 0 && li_loop_for(new_bb) < 0 { loop_add_basic_block_to_loop(parent_loop, new_bb); }
    var preds: i32[>..<] = [];
    if vp_is_header_block(vpbb) { preds.push(vp_pred(vpbb, 0)); } else { xv_to(vpb[vpbb].preds, preds); }
    for p in preds {
        let pvpbb = vp_exiting_basic_block(p);
        let pe = vp_enclosing_block_with_succs(pvpbb);
        let pbb = vts_bb_of(pvpbb);
        if pbb < 0 { fatal("internal: Predecessor basic-block not found building successor."); }
        let t = block_terminator(pbb);
        if iop(t) == OP_UNREACHABLE {
            let dl = inst_get_md(t, 0);
            inst_erase_from_parent(t);
            let br = create_inst(OP_BR, T_VOID, [new_bb]);
            block_append_inst(pbb, br);
            if dl >= 0 { inst_set_md(br, 0, dl); }
        } else if iop(t) == OP_BR {
            term_set_succ(t, 0, new_bb);
        } else {
            let idx: i64 = if vp_succ(pe, 0) == vpbb { 0 } else { 1 };
            term_set_succ(t, idx, new_bb);
        }
        dtu_apply_updates([DTUpdate { kind: DT_INSERT, from: pbb, to: new_bb }]);
    }
}

// VPIRBasicBlock::execute
fn vts_execute_ir_block(b: i32) {
    let irbb = vpb[b].irbb;
    if pred_count(irbb) == 0 && block_nsucc(irbb) == 0 { block_move_after(irbb, vts_prev_bb); }
    // IRBuilder::SetInsertPoint(Instruction) also takes the instruction's debug location
    vxb_set_before(block_terminator(irbb));
    vxb_dl = inst_get_md(block_terminator(irbb), 0);
    vts_prev_bb = irbb;
    hm_put(vts_bb, b as u64, irbb as i64);
    vts_execute_recipes(b);
    let t = block_terminator(irbb);
    if vp_single_succ(b) >= 0 && iop(t) == OP_UNREACHABLE {
        let br = vxb_insert(create_inst(OP_BR, T_VOID, [irbb]), "");
        set_op(br, 0, -1);
        inst_erase_from_parent(t);
    }
    vts_connect_to_predecessors(b);
}

// VPBasicBlock::execute
fn vts_execute_basic_block(b: i32) {
    if vp_is_header_block(b) {
        let prev = vts_parent_loop;
        vts_parent_loop = li_allocate_loop(vts_fv);
        if prev >= 0 { loop_add_child(prev, vts_parent_loop); } else { li_add_top_level_loop(vts_fv, vts_parent_loop); }
    }
    let new_bb = create_block_before(vts_fv, vts_exit_bb, sbytes(vpb[b].name));
    vxb_set_end(new_bb);
    let term = create_inst(OP_UNREACHABLE, T_VOID, []);
    block_append_inst(new_bb, term);
    if vxb_dl >= 0 { inst_set_md(term, 0, vxb_dl); }
    vxb_set_before(term);
    vts_prev_bb = new_bb;
    hm_put(vts_bb, b as u64, new_bb as i64);
    vts_connect_to_predecessors(b);
    vts_execute_recipes(b);
    if vp_is_latch_block(b) { vts_parent_loop = loop_parent(vts_parent_loop); }
}

// VPBasicBlock::executeRecipes
fn vts_execute_recipes(b: i32) {
    var r = vpb[b].first;
    while r >= 0 {
        vxb_dl = vpr[r].dl;
        vp_execute_recipe(r);
        r = vpr[r].next;
    }
}

// VPlan::execute
fn vts_execute_plan() {
    var shallow: i32[>..<] = [];
    vp_depth_first(vph.entry, false, shallow);
    for b in shallow { if vp_is_region(b) { fatal("internal: all region blocks must be dissolved before ::execute"); } }
    vts_exit_bb = vts_single_succ_bb(vts_prev_bb);
    vp_dt_build();
    let vector_ph = vts_prev_bb;
    term_set_succ(block_terminator(vector_ph), 0, -1);
    dtu_apply_updates([DTUpdate { kind: DT_DELETE, from: vector_ph, to: vts_exit_bb }]);
    vph.name = intern("Final VPlan");
    let scalar_ph = vts_exit_bb;
    let sph = vp_scalar_preheader();
    if sph >= 0 { dtu_apply_updates([DTUpdate { kind: DT_DELETE, from: scalar_ph, to: vts_single_succ_bb(scalar_ph) }]); }
    var rpo: i32[>..<] = [];
    vp_rpo(vph.entry, false, rpo);
    for b in rpo {
        if vp_is_ir_basic(b) { vts_execute_ir_block(b); } else { vts_execute_basic_block(b); }
    }
    if vp_has_early_exit() { vp_unported("early exits (dispatch block loop info)"); }
    if sph < 0 {
        // the original loop is unreachable: delete it and all its blocks
        for j in xv_len(vph.exit_blocks) {
            let eb = xv_get(vph.exit_blocks, j);
            var phis: i32[>..<] = [];
            vp_block_phis(eb, phis);
            for r in phis { if vp_nops(r) == 1 { vp_erase_recipe(r); } }
        }
        let orig = li_loop_for(vpb[vph.scalar_header].irbb);
        var blocks: i32[>..<] = [];
        for k in loop_nblocks(orig) { blocks.push(loop_block(orig, k)); }
        blocks.push(scalar_ph);
        if !loop_is_innermost(orig) { vp_unported("deleting a scalar loop with subloops"); }
        lu_li_erase(vts_fv, orig);
        for b in blocks { li_remove_block(b); }
        let sdtu = cu_dtu;
        cu_dtu = true;
        cu_delete_dead_blocks(blocks, false);
        cu_dtu = sdtu;
    }
    dtu_flush();
    for vb_ in shallow {
        if !vp_is_header_block(vb_) { continue; }
        let latch = vp_pred(vb_, 1);
        let latch_bb = vts_bb_of(latch);
        var phis: i32[>..<] = [];
        vp_block_phis(vb_, phis);
        for r in phis {
            let needs_scalar = vp_is_vp_phi(r) || (vpr[r].kind == VPR_REDUCTION_PHI && vpr[r].rdx_style != VRS_UNORDERED);
            let phi = vts_get(vpr[r].def, needs_scalar);
            let val = vts_get(vp_op(r, 1), needs_scalar);
            phi_add_incoming(phi, val, latch_bb);
        }
    }
}
fn vts_single_succ_bb(bb: i32) -> i32 { if block_nsucc(bb) == 1 { block_succ(bb, 0) } else { -1 } }
