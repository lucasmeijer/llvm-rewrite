// VPlan-to-VPlan transforms of llvm/lib/Transforms/Vectorize/VPlanTransforms.cpp used while building plans:
// simplifyRecipes (tryToFoldLiveIns, simplifyLogicalRecipe, simplifyRecipe), removeDeadRecipes, optimize() and its
// passes (removeRedundantInductionCasts, reassociateHeaderMask, simplifyBlends, legalizeAndOptimizeInductions with
// createScalarIVSteps, narrowToSingleScalarRecipes, removeRedundantExpandSCEVRecipes, removeBranchOnConst,
// simplifyReverses, createAndOptimizeReplicateRegions, mergeBlocksIntoPredecessors, licm),
// optimizeInductionLiveOutUsers (tryToComputeEndValueForInduction, optimizeLatchExitInductionUser),
// dropPoisonGeneratingRecipes, and the plan-building steps that are no-ops without reductions, recurrences,
// interleave groups, predication or tail folding (each checks that and fails loudly otherwise).
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import pm;
import apint;
import instsimplify;
import scev;
import scev_create;
import scev_expander;
import pse;
import iv_descriptors;
import lv_legality;
import vplan;
import vplan_utils;
import vplan_props;
import memloc;
import tbaa;

// ---------------------------------------------------------------------------------------------
// simplifyRecipes

// getOpcodeOrIntrinsicID: (is intrinsic, opcode or IID), or (false, -1)
fn vpt_opcode_or_iid(r: i32) -> bool, i32 {
    let id = vp_intrinsic_id(r);
    if id != 0 { return true, id; }
    let k = vpr[r].kind;
    if k == VPR_INSTRUCTION || k == VPR_WIDEN || k == VPR_WIDEN_CAST || k == VPR_REPLICATE { return false, vpr[r].opcode; }
    if k == VPR_WIDEN_GEP { return false, OP_GEP as i32; }
    if k == VPR_WIDEN_PHI { return false, OP_PHI as i32; }
    if k == VPR_VECTOR_POINTER || k == VPR_PRED_INST_PHI || k == VPR_SCALAR_IV_STEPS { return false, 2000 + (k as i32); }
    return false, -1;
}

// tryToFoldLiveIns: the live-in VPValue or -1
fn vpt_try_to_fold_live_ins(r: i32) -> i32 {
    let is_iid, oc = vpt_opcode_or_iid(r);
    if oc < 0 { return -1; }
    var ops: i32[>..<] = [];
    for k in vp_nops(r) {
        var c = vp_op(r, k);
        let d = vp_def(c);
        if d >= 0 && vp_is_vpi(d, VPI_BROADCAST) { c = vp_op(d, 0); }
        let ck = vpv[c].kind;
        if ck != VVK_IR && ck != VVK_SYMBOLIC && ck != VVK_REGION { return -1; }
        let v = vpv[c].uv;
        if v < 0 { return -1; }
        ops.push(v);
    }
    if is_iid { vp_unported("folding live-in intrinsic operands (FoldIntrinsic)"); }
    var res: i32 = -1;
    let o = oc as i64;
    if o >= OP_ADD && o <= OP_XOR { res = sxf_binop(o, ops[0], ops[1]); }
    else if is_cast_op(o) && oc < 1000 { res = sxf_cast(o, ops[0], vpv[vpr[r].def].ty); }
    else if oc == VPI_NOT { res = sxf_binop(OP_XOR, ops[0], c_all_ones_lv(vals[ops[0]].ty as i32)); }
    else if o == OP_SELECT { res = sxf_select(ops[0], ops[1], ops[2]); }
    else if o == OP_ICMP || o == OP_FCMP { res = sxf_cmp(vpr[r].f.pred as i64, ops[0], ops[1]); }
    else if o == OP_GEP || oc == VPI_PTR_ADD || oc == VPI_WIDE_PTR_ADD { vp_unported("folding live-in GEP operands (FoldGEP)"); }
    else if o == OP_EXTRACTELEMENT { res = ops[0]; }
    if res >= 0 { return vp_live_in(res); }
    return -1;
}
fn c_all_ones_lv(t: i32) -> i32 { c_int(t, -1) }

fn vpt_replace_all(r: i32, v: i32) { vp_rauw(vpr[r].def, v); }
// VPBuilder::createWidenCast at the builder's insert point
fn vpt_widen_cast(o: i64, v: i32, ty: i32) -> i32 {
    let r = vp_new_single_def(VPR_WIDEN_CAST, [v], ty, -1, -1);
    vpr[r].opcode = o as i32;
    vpr[r].f = vp_default_flags(o as i32, ty);
    return vpb_insert(r);
}

// simplifyRecipe(Def)
fn vpt_simplify_recipe(r: i32) {
    let fv = vpt_try_to_fold_live_ins(r);
    if fv >= 0 { vpt_replace_all(r, fv); return; }
    let k = vpr[r].kind;
    let def = vpr[r].def;
    if k == VPR_PRED_INST_PHI { vp_unported("simplifying VPPredInstPHIRecipe"); }
    if k == VPR_REPLICATE && vpr[r].predicated && iop(vp_underlying_instr(r)) == OP_STORE { vp_unported("simplifying predicated stores"); }
    let can_create = k != VPR_INSTRUCTION || vpv[def].uv < 0;
    let opc = vpm_opcode(r, true);
    // trunc (zext/sext A)
    if opc == OP_TRUNC as i32 && vpm_arity_ok(r, 1) {
        let s = vp_def(vp_op(r, 0));
        let so = vpm_opcode(s, true);
        if (so == OP_ZEXT as i32 || so == OP_SEXT as i32) && vpm_arity_ok(s, 1) { vp_unported("simplifying trunc(ext)"); }
    }
    // simplifyLogicalRecipe
    if vpt_simplify_logical_recipe(r, can_create) { return; }
    if opc == OP_ADD as i32 && vpm_arity_ok(r, 2) {
        if vpm_zero_int(vp_op(r, 1)) { vpt_replace_all(r, vp_op(r, 0)); return; }
        if vpm_zero_int(vp_op(r, 0)) { vpt_replace_all(r, vp_op(r, 1)); return; }
    }
    if opc == OP_MUL as i32 && vpm_arity_ok(r, 2) {
        if vpm_one(vp_op(r, 1)) { vpt_replace_all(r, vp_op(r, 0)); return; }
        if vpm_one(vp_op(r, 0)) { vpt_replace_all(r, vp_op(r, 1)); return; }
        if vpm_zero_int(vp_op(r, 1)) || vpm_zero_int(vp_op(r, 0)) { vpt_replace_all(r, vp_const_int(vpv[def].ty, 0)); return; }
        if can_create && (vpm_all_ones(vp_op(r, 0)) || vpm_all_ones(vp_op(r, 1))) { vp_unported("simplifying mul by -1"); }
    }
    if can_create && opc == OP_ADD as i32 && vpm_arity_ok(r, 2) {
        for j in 2 {
            let ok, a, b = vpm_binary(vp_op(r, j), OP_SUB);
            if ok && vpm_zero_int(a) { vp_unported("simplifying x + (0 - y)"); }
        }
    }
    if can_create && opc == OP_MUL as i32 && vpm_arity_ok(r, 2) {
        for j in 2 {
            let c = vp_op(r, j);
            if vp_is_constant_int(c) && ap_is_pow2(ci_ap(vp_ir(c))) { vp_unported("simplifying mul by a power of two"); }
        }
    }
    if can_create && opc == OP_UDIV as i32 && vpm_arity_ok(r, 2) {
        let c = vp_op(r, 1);
        if vp_is_constant_int(c) && ap_is_pow2(ci_ap(vp_ir(c))) { vp_unported("simplifying udiv by a power of two"); }
    }
    let not_a = vpm_not(def);
    if not_a >= 0 {
        let a = not_a;
        let ad = vp_def(a);
        let aa = vpm_not(a);
        if aa >= 0 { vpt_replace_all(r, aa); return; }
        let ao = vpm_opcode(ad, true);
        if (ao == OP_ICMP as i32 || ao == OP_FCMP as i32) && vpm_arity_ok(ad, 2) {
            var all = true;
            for j in vp_num_users(a) {
                let u = vp_user(a, j);
                let uv = vpr[u].def;
                if uv < 0 { all = false; break; }
                let is_not = vpm_not(uv) == a;
                let oks, sc, st, sf = vpm_select(uv);
                if !(is_not || (oks && sc == a)) { all = false; break; }
            }
            if all {
                let p = vpr[ad].f.pred as i64;
                let ip = if ao == OP_FCMP as i32 { 15 - p } else { pred_inverse_vpt(p) };
                vpr[ad].f.pred = ip as u8;
                var users: i32[>..<] = [];
                vp_users(a, users);
                for u in users {
                    let uv = vpr[u].def;
                    let oks, sc, st, sf = vpm_select(uv);
                    if oks && sc == a { vp_set_operand(u, 1, sf); vp_set_operand(u, 2, st); }
                    else { vp_rauw(uv, a); }
                }
                if vpr[ad].dl < 0 && vpr[r].dl >= 0 { vpr[ad].dl = vpr[r].dl; }
            }
        }
    }
    if opc == VPI_ANY_OF { vp_unported("simplifying any-of"); }
    if k == VPR_DERIVED_IV {
        if ((vpm_zero_int(vp_op(r, 0)) && vpm_one(vp_op(r, 2))) || (vpm_zero_int(vp_op(r, 0)) && vpm_zero_int(vp_op(r, 1)))) &&
           vp_scalar_type(vp_op(r, 1)) == vpv[def].ty {
            vpt_replace_all(r, vp_op(r, 1));
            return;
        }
    }
    if opc == VPI_WIDE_IV_STEP && vpm_arity_ok(r, 2) && vpm_one(vp_op(r, 1)) {
        var x = vp_op(r, 0);
        let wty = vpv[def].ty;
        if vp_scalar_type(x) != wty { vpb_set_before(r); let wc = vpt_widen_cast(OP_TRUNC, x, wty); x = vpr[wc].def; }
        vpt_replace_all(r, x);
        return;
    }
    if opc == VPI_MASKED_COND { vp_unported("simplifying masked-cond"); }
    if opc == VPI_EXTRACT_LAST_LANE && vpm_arity_ok(r, 1) {
        let a = vp_op(r, 0);
        let ad = vp_def(a);
        if vp_is_vpi(ad, VPI_BUILD_VECTOR) { vpt_replace_all(r, vp_op(ad, vp_nops(ad) - 1)); return; }
        if vp_is_vpi(ad, VPI_BROADCAST) { vpt_replace_all(r, vp_op(ad, 0)); return; }
        if ad >= 0 && (vpr[ad].kind == VPR_INSTRUCTION || vpr[ad].kind == VPR_REPLICATE) && vp_is_single_scalar(a) { vpt_replace_all(r, a); return; }
        if vp_has_scalar_vf_only() { vpt_replace_all(r, a); return; }
    }
    if opc == VPI_EXTRACT_PENULTIMATE_ELEMENT && vp_is_vpi(vp_def(vp_op(r, 0)), VPI_BUILD_VECTOR) { vp_unported("simplifying extract-penultimate(build-vector)"); }
    if opc == VPI_BUILD_VECTOR { vp_unported("simplifying build-vector"); }
    if opc == OP_SELECT as i32 && vpm_arity_ok(r, 3) && vp_is_vpi(vp_def(vp_op(r, 0)), VPI_BROADCAST) {
        vp_set_operand(r, 0, vp_op(vp_def(vp_op(r, 0)), 0));
        return;
    }
    if opc == VPI_BROADCAST && vpm_arity_ok(r, 1) {
        let x = vp_op(r, 0);
        vp_replace_uses_with_if(def, x) { u, i => vp_uses_scalars(u, def) };
        return;
    }
    if vp_is_vp_phi(r) || k == VPR_WIDEN_PHI || vp_is_header_phi_kind(k) {
        if vp_nops(r) == 1 { vpt_replace_all(r, vp_op(r, 0)); return; }
        if k == VPR_FIRST_ORDER_RECURRENCE_PHI { vp_unported("simplifying fixed-order recurrence phis"); }
        return;
    }
    if opc == VPI_COMPUTE_REDUCTION_RESULT && vp_nops(r) == 1 && vp_is_ir_value(vp_op(r, 0)) { vpt_replace_all(r, vp_op(r, 0)); return; }
    if !vp_is_unrolled() { return; }
    if opc == VPI_EXTRACT_LANE { vp_unported("simplifying extract-lane"); }
    // phi(0, IVInc) + Y fold
    if opc == OP_ADD as i32 && vpm_arity_ok(r, 2) {
        let ok, x, step = vpm_binary(vp_op(r, 0), OP_ADD);
        let y = vp_op(r, 1);
        if ok && vp_is_ir_value(y) {
            let xd = vp_def(x);
            if vp_is_vp_phi(xd) && vp_nops(xd) == 2 && vpm_zero_int(vp_op(xd, 0)) && vp_op(xd, 1) == vp_op(r, 0) {
                vp_unported("folding phi(0, IVInc) + Y");
            }
        }
    }
    if k == VPR_VECTOR_POINTER {
        if vp_nops(r) < 3 || vpm_zero_int(vp_op(r, 2)) { vpt_replace_all(r, vp_op(r, 0)); return; }
    }
    if k == VPR_SCALAR_IV_STEPS {
        if vp_nops(r) < 4 && vp_only_first_lane_used(def) { vpt_replace_all(r, vp_op(r, 0)); return; }
    }
    if opc == VPI_REDUCTION_START_VECTOR && vpm_arity_ok(r, 3) {
        let sv = vp_op(r, 0);
        var users: i32[>..<] = [];
        for j in vp_num_users(def) { users.push(vp_user(def, j)); }
        for u in users {
            if vpr[u].kind != VPR_REDUCTION_PHI || vpr[u].rdx_style == VRS_UNORDERED { continue; }
            for k in vp_nops(u) { if vp_op(u, k) == def { vp_set_operand(u, k, sv); } }
        }
        return;
    }
    if xv_len(vph.ufs) == 1 && xv_get(vph.ufs, 0) == 1 && opc == VPI_EXTRACT_LAST_PART && vpm_arity_ok(r, 1) {
        vpt_replace_all(r, vp_op(r, 0));
        return;
    }
}

// matchers for simplifyLogicalRecipe
fn vpm_i1(v: i32, x: u64) -> bool {
    let c = vpm_through_broadcast(v);
    return vp_is_constant_int(c) && ty_bits(vp_scalar_type(c)) == 1 && cint_lo(vp_ir(c)) == x;
}
fn vpm_true(v: i32) -> bool { vpm_i1(v, 1) }
fn vpm_false(v: i32) -> bool { vpm_i1(v, 0) }
// m_Select(A, B, C) (AllRecipe_match): (ok, A, B, C)
fn vpm_select(v: i32) -> bool, i32, i32, i32 {
    let r = vp_def(v);
    if vpm_opcode(r, true) != OP_SELECT as i32 || !vpm_arity_ok(r, 3) { return false, -1, -1, -1; }
    return true, vp_op(r, 0), vp_op(r, 1), vp_op(r, 2);
}
// m_LogicalAnd(A, B): logical-and(A, B) or select(A, B, false)
fn vpm_logical_and(v: i32) -> bool, i32, i32 {
    let r = vp_def(v);
    if vpm_vpi_r(r, VPI_LOGICAL_AND, 2) { return true, vp_op(r, 0), vp_op(r, 1); }
    let ok, a, b, c = vpm_select(v);
    if ok && vpm_false(c) { return true, a, b; }
    return false, -1, -1;
}
// m_Not(X): not(X) or xor with all-ones (commutative): X or -1
fn vpm_not(v: i32) -> i32 {
    let r = vp_def(v);
    if vpm_vpi_r(r, VPI_NOT, 1) { return vp_op(r, 0); }
    if vpm_opcode(r, false) == OP_XOR as i32 && vpm_arity_ok(r, 2) {
        if vpm_all_ones(vp_op(r, 0)) { return vp_op(r, 1); }
        if vpm_all_ones(vp_op(r, 1)) { return vp_op(r, 0); }
    }
    return -1;
}
// m_c_Binary<Opc> (AllRecipe_commutative_match, no casts): (ok, A, B)
fn vpm_c_binop(v: i32, o: i64) -> bool, i32, i32 {
    let r = vp_def(v);
    if vpm_opcode(r, false) != o as i32 || !vpm_arity_ok(r, 2) { return false, -1, -1; }
    return true, vp_op(r, 0), vp_op(r, 1);
}

// simplifyLogicalRecipe(Def, Builder, CanCreateNewRecipe)
fn vpt_simplify_logical_recipe(r: i32, can_create: bool) -> bool {
    let def = vpr[r].def;
    let ty = vpv[def].ty;
    // (X && Y) | (X && !Y) -> X
    let oko, o0, o1 = vpm_c_binop(def, OP_OR);
    if oko {
        for j in 2 {
            let p = if j == 0 { o0 } else { o1 };
            let q = if j == 0 { o1 } else { o0 };
            let ok1, x, y = vpm_logical_and(p);
            let ok2, x2, ny = vpm_logical_and(q);
            if ok1 && ok2 && x2 == x && vpm_not(ny) == y && y >= 0 { vp_rauw(def, x); vp_erase_recipe(r); return true; }
        }
        // x | AllOnes -> AllOnes; x | 0 -> x; x | !x -> AllOnes
        if vpm_all_ones(o1) || vpm_all_ones(o0) { vp_rauw(def, vp_live_in(c_all_ones_lv(ty))); return true; }
        if vpm_zero_int(o1) { vp_rauw(def, o0); return true; }
        if vpm_zero_int(o0) { vp_rauw(def, o1); return true; }
        if vpm_not(o1) == o0 || vpm_not(o0) == o1 { vp_rauw(def, vp_live_in(c_all_ones_lv(ty))); return true; }
    }
    let oka, a0, a1 = vpm_c_binop(def, OP_AND);
    if oka {
        if vpm_zero_int(a1) || vpm_zero_int(a0) { vp_rauw(def, vp_const_int(ty, 0)); return true; }
        if vpm_all_ones(a1) { vp_rauw(def, a0); return true; }
        if vpm_all_ones(a0) { vp_rauw(def, a1); return true; }
    }
    // m_c_LogicalAnd(X, false / true)
    let r0 = vp_def(def);
    var cla_ok = false;
    var cx: i32 = -1;
    var cy: i32 = -1;
    if vpm_vpi_r(r0, VPI_LOGICAL_AND, 2) { cla_ok = true; cx = vp_op(r0, 0); cy = vp_op(r0, 1); }
    if cla_ok {
        if vpm_false(cy) || vpm_false(cx) { vp_rauw(def, vp_false()); return true; }
        if vpm_true(cy) { vp_rauw(def, cx); return true; }
        if vpm_true(cx) { vp_rauw(def, cy); return true; }
    } else {
        // m_c_Select(X, false, false) / m_c_Select(X, true, false): select(X, Y, false) with X, Y commuted
        let oks, sc, st, sf = vpm_select(def);
        if oks && vpm_false(sf) {
            if vpm_false(st) || vpm_false(sc) { vp_rauw(def, vp_false()); return true; }
            if vpm_true(st) { vp_rauw(def, sc); return true; }
            if vpm_true(sc) { vp_rauw(def, st); return true; }
        }
    }
    if can_create && oko {
        let ok1, x, y = vpm_logical_and(o0);
        let ok2, x2, z = vpm_logical_and(o1);
        if ok1 && ok2 && x == x2 { vp_unported("simplifying (x && y) | (x && z)"); }
    }
    let okl, lx, ly = vpm_logical_and(def);
    if okl {
        let ok2, ix, iy = vpm_logical_and(ly);
        if ok2 && ix == lx { vp_rauw(def, ly); return true; }
        if ok2 && iy == lx { vp_unported("simplifying x && (y && x)"); }
        if vpm_not(ly) == lx && lx >= 0 { vp_rauw(def, vp_false()); return true; }
    }
    let oks, c, t, f = vpm_select(def);
    if oks {
        if t == f { vp_rauw(def, t); return true; }
        if can_create && vpm_false(t) && vpm_true(f) { vp_unported("simplifying select c, false, true"); }
        let nc = vpm_not(c);
        if nc >= 0 {
            vp_set_operand(r, 0, nc);
            vp_set_operand(r, 1, f);
            vp_set_operand(r, 2, t);
            return true;
        }
        if can_create && vp_has_one_use(t) {
            let okb, b0, b1 = vpm_c_binop(t, OP_OR);
            if okb && (b0 == f || b1 == f) && ty_bits(vp_scalar_type(f)) == 1 && ty_is_int(vp_scalar_type(f)) {
                vp_unported("simplifying select x, (y | z), y");
            }
        }
    }
    return false;
}

fn vpt_simplify_recipes() {
    var rpo: i32[>..<] = [];
    vp_rpo(vph.entry, true, rpo);
    for b in rpo {
        if !vp_is_basic(b) { continue; }
        var rs: i32[>..<] = [];
        vp_block_recipes(b, rs);
        for r in rs {
            if vpr[r].dead || vpr[r].parent != b { continue; }
            if vpr[r].def >= 0 { vpt_simplify_recipe(r); }
        }
    }
}

// removeDeadRecipes
fn vpt_remove_dead_recipes() {
    var rpo: i32[>..<] = [];
    vp_rpo(vph.entry, true, rpo);
    var k = rpo.len - 1;
    while k >= 0 {
        let b = rpo[k];
        k--;
        if !vp_is_basic(b) { continue; }
        var r = vpb[b].last;
        while r >= 0 {
            let prev = vpr[r].prev;
            if vp_is_dead_recipe(r) { vp_erase_recipe(r); r = prev; continue; }
            if vp_is_vp_phi(r) && vp_nops(r) == 2 {
                let start = vp_op(r, 0);
                let inc = vp_op(r, 1);
                let pu = vp_single_user(vpr[r].def);
                if pu >= 0 && pu == vp_def(inc) && vp_num_users(inc) == 1 {
                    vp_rauw(vpr[r].def, start);
                    // the phi and its increment; `prev` may be the increment
                    let incr = vp_def(inc);
                    var np = prev;
                    if np == incr { np = vpr[incr].prev; }
                    if np == r { np = vpr[r].prev; }
                    vp_erase_recipe(r);
                    vp_erase_recipe(incr);
                    r = np;
                    continue;
                }
            }
            r = prev;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// optimize()

fn vp_header_bb() -> i32 { vpb[vp_vector_loop_region()].entry }

// removeRedundantInductionCasts
fn vpt_remove_redundant_induction_casts() {
    var phis: i32[>..<] = [];
    vp_block_phis(vp_header_bb(), phis);
    for p in phis {
        if vpr[p].kind != VPR_WIDEN_INT_OR_FP_INDUCTION || vpr[p].ir_inst >= 0 { continue; }
        let d = vpr[p].ind;
        var find = vpr[p].def;
        var k = (ind_descs[d].casts_n as i64) - 1;
        while k >= 0 {
            let cast = ind_cast(d, k);
            k--;
            var found: i32 = -1;
            for j in vp_num_users(find) {
                let u = vp_user(find, j);
                if vpr[u].def >= 0 && vpv[vpr[u].def].uv == cast { found = vpr[u].def; break; }
            }
            if found < 0 { break; }
            find = found;
        }
        if find != vpr[p].def { vp_rauw(find, vpr[p].def); }
    }
}

// VPBuilder::createDerivedIV + createScalarIVSteps
fn vp_new_derived_iv(kind: i32, fp_binop: i32, start: i32, iv: i32, step: i32) -> i32 {
    let r = vp_new_single_def(VPR_DERIVED_IV, [start, iv, step], vp_scalar_type(start), -1, -1);
    vpr[r].ind_kind = kind as u8;
    vpr[r].fp_binop = fp_binop;
    return r;
}
fn vp_create_scalar_iv_steps(kind: i32, ind_opcode: i64, fp_binop: i32, trunc: i32, start: i32, step0: i32, dl: i32) -> i32 {
    let region = vp_vector_loop_region();
    let header = vpb[region].entry;
    let can_iv = vpb[region].can_iv;
    let dr = vp_new_derived_iv(kind, fp_binop, start, can_iv, step0);
    var base = vpb_insert(dr);
    var rty = vpv[vpr[base].def].ty;
    if trunc >= 0 {
        let tt = vals[trunc].ty as i32;
        base = vpb_scalar_cast(OP_TRUNC, vpr[base].def, tt, dl, vpf_none());
        rty = tt;
    }
    var step = step0;
    if rty != vp_scalar_type(step) {
        let ph = vp_single_hierarchical_pred(header);
        let sbb = vpbld_bb;
        let sip = vpbld_ip;
        vpb_set_at_end(ph);
        step = vp_val(vpb_scalar_cast(OP_TRUNC, step, rty, dl, vpf_none()));
        vpbld_bb = sbb;
        vpbld_ip = sip;
    }
    let fmf: u8 = if fp_binop >= 0 { insts[inst_of(fp_binop)].fmf } else { 0 };
    let s = vp_new_single_def(VPR_SCALAR_IV_STEPS, [vpr[base].def, step, vph.vf], vp_scalar_type(vpr[base].def), -1, dl);
    vpr[s].ind_opcode = ind_opcode;
    vpr[s].f = vpf_fmf(fmf);
    return vpb_insert(s);
}

// legalizeAndOptimizeInductions
fn vpt_legalize_and_optimize_inductions() {
    let header = vp_header_bb();
    let has_only_vector_vfs = !vp_has_scalar_vf_only();
    var wide: i32[>..<] = [];
    var phis: i32[>..<] = [];
    vp_block_phis(header, phis);
    for p in phis { if vp_is_widen_induction_kind(vpr[p].kind) { wide.push(p); } }
    for p in wide {
        // collectUsersRecursively
        var users: i32[>..<] = [];
        var seen = hm_new();
        for j in vp_num_users(vpr[p].def) { let u = vp_user(vpr[p].def, j); if ivd_set_add(seen, u) { users.push(u); } }
        var i: i64 = 0;
        while i < users.len {
            let cur = users[i];
            i++;
            for d in vp_num_defined_values(cur) {
                let v = vp_defined_value(cur, d);
                for j in vp_num_users(v) { let u = vp_user(v, j); if ivd_set_add(seen, u) { users.push(u); } }
            }
        }
        var k = users.len - 1;
        while k >= 0 {
            let u = users[k];
            k--;
            if vpr[u].dead { continue; }
            let uk = vpr[u].kind;
            if uk != VPR_REPLICATE && uk != VPR_WIDEN { continue; }
            if vp_num_users(vpr[u].def) == 0 || vpv[vpr[u].def].uv < 0 { continue; }
            if uk == VPR_REPLICATE && (vpr[u].single_scalar || vpr[u].predicated) { continue; }
            if !vp_is_single_scalar(vpr[u].def) && !vp_only_first_lane_used(vpr[u].def) { continue; }
            if vpm_opcode(u, true) == OP_EXTRACTVALUE as i32 { continue; }
            var ops: i32[>..<] = [];
            xv_to(vpr[u].ops, ops);
            let ui = vp_underlying_instr(u);
            let c = vp_create_single_scalar_op(iop(ui) as i32, ops, -1, vpr[u].f, -1, -1, ui);
            vp_insert_after(c, u);
            vp_rauw(vpr[u].def, vpr[c].def);
            vp_erase_recipe(u);
        }
    }
    vpb_set_at(header, vp_first_non_phi(header));
    for p in wide {
        if vpr[p].kind == VPR_WIDEN_POINTER_INDUCTION {
            vp_unported("pointer inductions (legalizeAndOptimizeInductions)");
            continue;
        }
        let def = vpr[p].def;
        if has_only_vector_vfs {
            var any = false;
            for j in vp_num_users(def) { if vp_uses_scalars(vp_user(def, j), def) { any = true; } }
            if !any { continue; }
        }
        let d = vpr[p].ind;
        let bop = ind_descs[d].binop;
        let fpb = if bop >= 0 && is_fp_math_operator(bop) { bop } else { -1 };
        let steps = vp_create_scalar_iv_steps(ind_descs[d].kind, ind_opcode(d), fpb, vpr[p].ir_inst, vp_op(p, 0), vp_op(p, 1), vpr[p].dl);
        let sv = vpr[steps].def;
        if !has_only_vector_vfs { vp_rauw(def, sv); }
        else { vp_replace_uses_with_if(def, sv) { u, i => vp_uses_scalars(u, def) }; }
    }
}
fn vp_create_single_scalar_op(opc: i32, ops: const i32[:], mask: i32, f: VPF, md_from: i32, dl: i32, uv: i32) -> i32 {
    if vp_opcode_is_cast(opc) {
        let r = vp_new_instruction(opc, ops, f, dl, val_name(uv), vals[uv].ty as i32);
        vpr[r].with_type = true;
        vp_set_underlying(vpr[r].def, uv);
        if md_from >= 0 { vp_md_copy(r, md_from); }
        return r;
    }
    let r = vp_new_single_def(VPR_REPLICATE, ops, vals[uv].ty as i32, uv, dl);
    if mask >= 0 { vp_add_operand(r, mask); vpr[r].predicated = true; }
    vpr[r].single_scalar = true;
    vpr[r].opcode = iop(uv) as i32;
    vpr[r].f = f;
    if md_from >= 0 { vp_md_copy(r, md_from); }
    return r;
}

// narrowToSingleScalarRecipes
fn vpt_narrow_to_single_scalar_recipes() {
    if vp_has_scalar_vf_only() { return; }
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    for b in bs {
        var r = vpb[b].last;
        while r >= 0 {
            let prev = vpr[r].prev;
            let k = vpr[r].kind;
            if k != VPR_WIDEN && k != VPR_WIDEN_GEP && k != VPR_REPLICATE && k != VPR_WIDEN_INTRINSIC { r = prev; continue; }
            if k == VPR_REPLICATE && (vpr[r].single_scalar || vpr[r].predicated) { r = prev; continue; }
            if k == VPR_REPLICATE && vpr[r].opcode == OP_STORE as i32 && vp_is_single_scalar(vp_op(r, 1)) {
                vp_unported("narrowing replicated stores to a single-scalar address");
            }
            if k == VPR_WIDEN_INTRINSIC { vp_unported("narrowing widened intrinsics"); }
            if !vp_is_single_scalar(vpr[r].def) { r = prev; continue; }
            let def = vpr[r].def;
            fn intro_bcast(opv: i32, u: i32) -> bool {
                if vpr[u].kind == VPR_INSTRUCTION {
                    let o = vpr[u].opcode;
                    if o == VPI_EXTRACT_LAST_LANE || o == VPI_EXTRACT_LAST_PART || o == VPI_EXTRACT_PENULTIMATE_ELEMENT { return false; }
                }
                return !vp_uses_scalars(u, opv);
            }
            var any_user = false;
            for j in vp_num_users(def) { if intro_bcast(def, vp_user(def, j)) { any_user = true; } }
            var none_ops = true;
            for i in vp_nops(r) {
                let o = vp_op(r, i);
                var other_bcast = false;
                for j in vp_num_users(o) { let u = vp_user(o, j); if u != r && intro_bcast(o, u) { other_bcast = true; } }
                if other_bcast { continue; }
                let li_needs = vp_is_ir_value(o) && !vp_is_constant(o);
                let od = vp_def(o);
                if li_needs || (od >= 0 && vpr[od].kind == VPR_REPLICATE && vpr[od].single_scalar) { none_ops = false; }
            }
            if any_user && none_ops { r = prev; continue; }
            let is_iid, oc = vpt_opcode_or_iid(r);
            var ops: i32[>..<] = [];
            xv_to(vpr[r].ops, ops);
            let c = vp_create_single_scalar_op(oc, ops, -1, vpr[r].f, -1, -1, vpv[def].uv);
            vp_insert_before(c, r);
            vp_rauw(def, vpr[c].def);
            if vp_is_dead_recipe(r) { vp_erase_recipe(r); }
            r = prev;
        }
    }
}

// removeRedundantExpandSCEVRecipes
fn vpt_remove_redundant_expand_scev_recipes() {
    var m = hm_new();
    var rs: i32[>..<] = [];
    vp_block_recipes(vp_entry_basic_block(vph.entry), rs);
    for r in rs {
        if vpr[r].kind != VPR_EXPAND_SCEV { continue; }
        let e = vpr[r].expr;
        let x = hm_get(m, e as u64, -1);
        if x < 0 { hm_put(m, e as u64, vpr[r].def as i64); continue; }
        vp_rauw(vpr[r].def, x as i32);
        if vph.trip_count == vpr[r].def { vph.trip_count = x as i32; }
        vp_erase_recipe(r);
    }
}

// removeBranchOnConst(Plan, OnlyLatches)
fn vpt_remove_branch_on_const(only_latches: bool) -> bool {
    if only_latches { vp_unported("removeBranchOnConst(OnlyLatches)"); }
    var all: i32[>..<] = [];
    vp_depth_first(vph.entry, false, all);
    var simplified = false;
    for b in all {
        if !vp_is_basic(b) || vp_block_empty(b) { continue; }
        let t = vpb[b].last;
        if !vpm_vpi_r(t, VPI_BRANCH_ON_COND, 1) { continue; }
        let c = vp_op(t, 0);
        var removed: i64 = -1;
        if vp_is_constant_int(c) && ty_bits(vp_scalar_type(c)) == 1 {
            removed = if vp_is_const_int_one(c) { 1 } else { 0 };
        } else { continue; }
        let rs = vp_succ(b, removed);
        var phis: i32[>..<] = [];
        vp_block_phis(rs, phis);
        for p in phis { vp_phi_remove_incoming_value_for(p, b); }
        if phis.len > 0 { simplified = true; }
        vpbu_disconnect(b, rs);
        vp_erase_recipe(vpb[b].last);
    }
    var reach: i32[>..<] = [];
    vp_depth_first(vph.entry, false, reach);
    var rset = hm_new();
    for b in reach { hm_put(rset, b as u64, 1); }
    let tmp = vp_new_symbolic(-1);
    for b in all {
        if hm_has(rset, b as u64) { continue; }
        var ss: i32[>..<] = [];
        xv_to(vpb[b].succs, ss);
        for s in ss {
            if vp_is_basic(s) {
                var phis: i32[>..<] = [];
                vp_block_phis(s, phis);
                for p in phis { vp_phi_remove_incoming_value_for(p, b); }
            }
            vpbu_disconnect(b, s);
        }
        var dead: i32[>..<] = [];
        vp_depth_first(b, true, dead);
        vp_only_basic(dead);
        for db in dead {
            var rs: i32[>..<] = [];
            vp_block_recipes(db, rs);
            for r in rs {
                for d in vp_num_defined_values(r) { vp_rauw(vp_defined_value(r, d), tmp); }
                vp_erase_recipe(r);
            }
        }
    }
    return simplified;
}

// mergeBlocksIntoPredecessors
fn vpt_merge_blocks_into_predecessors() -> bool {
    var wl: i32[>..<] = [];
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    for b in bs {
        if vpb[b].parent < 0 { continue; }
        let p = vp_single_pred(b);
        if p < 0 || !vp_is_basic(p) || vp_nsuccs(p) != 1 || vp_is_ir_basic(p) { continue; }
        wl.push(b);
    }
    for b in wl {
        let p = vp_single_pred(b);
        var rs: i32[>..<] = [];
        vp_block_recipes(b, rs);
        for r in rs { vp_move_before(r, p, -1); }
        vpbu_disconnect(p, b);
        let pr = vpb[b].parent;
        if pr >= 0 && vpb[pr].exiting == b { vp_region_set_exiting(pr, p); }
        vpbu_transfer_successors(b, p);
        vpb[b].dead = true;
    }
    return wl.len > 0;
}

// isDefinedOutsideLoopRegions
fn vp_is_defined_outside_loop_regions(v: i32) -> bool {
    if vpv[v].kind == VVK_REGION { return false; }
    let r = vp_def(v);
    if r < 0 { return true; }
    if vp_vector_loop_region() < 0 { return false; }
    return vp_enclosing_loop_region(vpr[r].parent) < 0;
}

// licm
fn vpt_licm() {
    let ph = vp_vector_preheader();
    let region = vp_vector_loop_region();
    var bs: i32[>..<] = [];
    vp_depth_first(vpb[region].entry, false, bs);
    vp_only_basic(bs);
    for b in bs {
        var rs: i32[>..<] = [];
        vp_block_recipes(b, rs);
        for r in rs {
            if vpt_cannot_hoist_or_sink(r, false) { continue; }
            var inside = false;
            for k in vp_nops(r) { if !vp_is_defined_outside_loop_regions(vp_op(r, k)) { inside = true; } }
            if inside { continue; }
            vp_move_before(r, ph, -1);
        }
    }
    var rpo: i32[>..<] = [];
    vp_rpo(vpb[region].entry, false, rpo);
    var k = rpo.len - 1;
    while k >= 0 {
        let b = rpo[k];
        k--;
        if !vp_is_basic(b) { continue; }
        var r = vpb[b].last;
        while r >= 0 {
            let prev = vpr[r].prev;
            if vpt_cannot_hoist_or_sink(r, true) { r = prev; continue; }
            if vpr[r].kind == VPR_REPLICATE {
                if !vpr[r].single_scalar { r = prev; continue; }
                if vpr[r].opcode == OP_STORE as i32 && !vp_is_defined_outside_loop_regions(vp_op(r, 1)) { r = prev; continue; }
            }
            if vpr[r].def < 0 { vp_unported("licm sinking a multi-def recipe"); }
            let def = vpr[r].def;
            var sink: i32 = -1;
            var bad = false;
            for j in vp_num_users(def) {
                let u = vp_user(def, j);
                let par = vpr[u].parent;
                if sink >= 0 && sink != par { bad = true; break; }
                sink = par;
                if vp_is_phi_recipe(u) || vp_enclosing_loop_region(par) >= 0 || vp_single_pred(par) != region { bad = true; break; }
            }
            if bad { r = prev; continue; }
            if sink < 0 { sink = vp_single_succ(region); }
            vp_move_before(r, sink, vp_first_non_phi(sink));
            r = prev;
        }
    }
}
// cannotHoistOrSinkRecipe(R, FirstBB, LastBB, Sinking)
fn vpt_cannot_hoist_or_sink(r: i32, sinking: bool) -> bool {
    if vpr[r].kind != VPR_REPLICATE || !vp_may_read_or_write_memory(r) || vp_intrinsic_id(r) == IID_assume {
        return vp_cannot_hoist_or_sink_recipe(r, sinking);
    }
    // !canHoistOrSinkWithNoAliasCheck(getMemoryLocation(R), loop entry, loop exiting, SinkStoreInfo(R) when sinking)
    let region = vp_vector_loop_region();
    return !vpt_can_hoist_or_sink_with_no_alias_check(vpt_memory_location(r), vp_entry_basic_block(region),
                                                      vp_exiting_basic_block(region), if sinking { r } else { -1 });
}
// VPIRMetadata recipes (the ones vputils::getMemoryLocation gives a location for)
fn vpt_is_ir_metadata_recipe(r: i32) -> bool {
    let k = vpr[r].kind;
    return k == VPR_INSTRUCTION || k == VPR_WIDEN || k == VPR_WIDEN_CAST || k == VPR_WIDEN_INTRINSIC || k == VPR_WIDEN_MEM_INTRINSIC ||
           k == VPR_WIDEN_CALL || k == VPR_HISTOGRAM || k == VPR_INTERLEAVE || k == VPR_INTERLEAVE_EVL || k == VPR_REPLICATE ||
           vp_is_widen_memory_kind(k);
}
// vputils::getMemoryLocation(R): only the scoped-noalias tags matter
fn vpt_memory_location(r: i32) -> ML {
    var m = ml_make(-1, 0);
    m.noalias = vp_md_get(r, MDK_NOALIAS);
    m.scope = vp_md_get(r, MDK_ALIAS_SCOPE);
    return m;
}
// canHoistOrSinkWithNoAliasCheck(MemLoc, FirstBB, LastBB, SinkInfo): leader >= 0 is SinkStoreInfo(leader)
fn vpt_can_hoist_or_sink_with_no_alias_check(loc: ML, first: i32, last: i32, leader: i32) -> bool {
    let check_reads = leader >= 0;
    var bs: i32[>..<] = [];
    vp_depth_first(first, true, bs);
    vp_only_basic(bs);
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 {
            let nx = vpr[r].next;
            // SinkStoreInfo::shouldSkip: isNoAliasViaDistance without PSE is "both stores and the same recipe"
            if leader >= 0 && r == leader && vpr[r].kind == VPR_REPLICATE && vpr[r].opcode == OP_STORE as i32 { r = nx; continue; }
            if !vp_may_write_to_memory(r) && !(check_reads && vp_may_read_from_memory(r)) { r = nx; continue; }
            if !vpt_is_ir_metadata_recipe(r) { return false; }
            if sna_alias_may(vpt_memory_location(r), loc) { return false; }
            r = nx;
        }
        if b == last { break; }
    }
    return true;
}

// createAndOptimizeReplicateRegions
fn vpt_create_and_optimize_replicate_regions() {
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 {
            if vpr[r].kind == VPR_REPLICATE && vpr[r].predicated { vp_unported("replicate regions (predicated scalarization)"); }
            r = vpr[r].next;
        }
    }
    // sinkScalarOperands and mergeReplicateRegionsIntoSuccessors only act on replicate regions
    while vpt_merge_blocks_into_predecessors() {}
}

fn vpt_reassociate_header_mask() {
    if vpb[vp_vector_loop_region()].header_mask >= 0 { vp_unported("reassociateHeaderMask"); }
}
fn vpt_simplify_blends() {
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 { if vpr[r].kind == VPR_BLEND { vp_unported("blends (simplifyBlends)"); } r = vpr[r].next; }
    }
}
fn vpt_simplify_reverses() {
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 { if vp_is_vpi(r, VPI_REVERSE) { vp_unported("reverse accesses (simplifyReverses)"); } r = vpr[r].next; }
    }
}

// VPlanTransforms::optimize
fn vpt_optimize() {
    vpt_remove_redundant_induction_casts();
    vpt_reassociate_header_mask();
    vpt_simplify_recipes();
    vpt_remove_dead_recipes();
    vpt_simplify_blends();
    vpt_legalize_and_optimize_inductions();
    vpt_narrow_to_single_scalar_recipes();
    vpt_remove_redundant_expand_scev_recipes();
    vpt_reassociate_header_mask();
    vpt_simplify_recipes();
    vpt_remove_branch_on_const(false);
    vpt_simplify_reverses();
    vpt_remove_dead_recipes();
    vpt_create_and_optimize_replicate_regions();
    vpt_merge_blocks_into_predecessors();
    vpt_licm();
}

// ---------------------------------------------------------------------------------------------
// optimizeInductionLiveOutUsers

// m_CanonicalWidenIV: an int induction starting at 0 with step 1 of the canonical IV's type, untruncated
fn vp_is_canonical_widen_iv(r: i32) -> bool {
    if vpr[r].kind != VPR_WIDEN_INT_OR_FP_INDUCTION || vpr[r].ir_inst >= 0 { return false; }
    let d = vpr[r].ind;
    if ind_descs[d].kind != IK_INT { return false; }
    return vpm_zero_int(vp_op(r, 0)) && vpm_one(vp_op(r, 1)) && vp_scalar_type(vp_op(r, 0)) == vpv[vpb[vp_vector_loop_region()].can_iv].ty;
}

// tryToComputeEndValueForInduction: the end value or -1 (the builder is at the vector preheader's start)
fn vpt_end_value_for_induction(w: i32, vtc: i32) -> i32 {
    if vpr[w].kind == VPR_WIDEN_INT_OR_FP_INDUCTION && vpr[w].ir_inst >= 0 { return -1; }
    let start = vp_op(w, 0);
    let step = vp_op(w, 1);
    let d = vpr[w].ind;
    var end = vtc;
    if !vp_is_canonical_widen_iv(w) {
        let b = ind_descs[d].binop;
        let fpb = if b >= 0 && is_fp_math_operator(b) { b } else { -1 };
        let dr = vpb_insert(vp_new_derived_iv(ind_descs[d].kind, fpb, start, vtc, step));
        end = vpr[dr].def;
    }
    let sty = vpv[vpr[w].def].ty;
    if sty != vp_scalar_type(end) {
        end = vp_val(vpb_scalar_cast(OP_TRUNC, end, sty, vpr[w].dl, vpf_none()));
    }
    return end;
}

fn vpt_optimize_induction_live_out_users(pse: i32) {
    let region = vp_vector_loop_region();
    let vph_ = vp_single_pred(region);
    var ends = hm_new();
    let resume_tc = if vp_has_tail_folded() { vph.trip_count } else { vph.vtc };
    var phis: i32[>..<] = [];
    vp_block_phis(vpb[region].entry, phis);
    for p in phis {
        if !vp_is_widen_induction_kind(vpr[p].kind) { continue; }
        vpb_set_at(vph_, vpb[vph_].first);
        let e = vpt_end_value_for_induction(p, resume_tc);
        if e >= 0 { hm_put(ends, p as u64, e as i64); }
    }
    let middle = vp_middle_block();
    var rs: i32[>..<] = [];
    vp_block_recipes(middle, rs);
    for r in rs {
        if !vpm_vpi_r(r, VPI_EXITING_IV_VALUE, 1) { continue; }
        let w = vp_def(vp_op(r, 0));
        let e = hm_get(ends, w as u64, -1);
        if e >= 0 { vp_rauw(vpr[r].def, e as i32); vp_erase_recipe(r); }
    }
    for j in xv_len(vph.exit_blocks) {
        let eb = xv_get(vph.exit_blocks, j);
        var ephis: i32[>..<] = [];
        vp_block_phis(eb, ephis);
        for p in ephis {
            for idx in vp_npreds(eb) {
                let pb = vp_pred(eb, idx);
                if pb == middle {
                    let esc = vpt_optimize_latch_exit_induction_user(vp_op(p, idx), ends, pse);
                    if esc >= 0 { vp_set_operand(p, idx, esc); }
                } else {
                    vp_unported("induction users in early exits (optimizeEarlyExitInductionUser)");
                }
            }
        }
    }
}

// getOptimizableIVOf(VPV, PSE): the header IV recipe or -1
fn vpt_optimizable_iv_of(v: i32) -> i32 {
    let d = vp_def(v);
    if d >= 0 && vp_is_widen_induction_kind(vpr[d].kind) {
        if vpr[d].kind == VPR_WIDEN_INT_OR_FP_INDUCTION && vpr[d].ir_inst >= 0 { return -1; }
        return d;
    }
    if d < 0 || vp_nops(d) != 2 { return -1; }
    var w = vp_def(vp_op(d, 0));
    if w < 0 || !vp_is_widen_induction_kind(vpr[w].kind) { w = vp_def(vp_op(d, 1)); }
    if w < 0 || !vp_is_widen_induction_kind(vpr[w].kind) { return -1; }
    let desc = vpr[w].ind;
    let step = vp_op(w, 1);
    let wv = vpr[w].def;
    let o = ind_opcode(desc);
    var is_inc = false;
    if o == OP_ADD { let x = vpm_c_binary_with(v, OP_ADD, wv); is_inc = x == step && x >= 0; }
    else if o == OP_FADD { let x = vpm_c_binary_with(v, OP_FADD, wv); is_inc = x == step && x >= 0; }
    else if o == OP_FSUB { let ok, a, b = vpm_binary(v, OP_FSUB); is_inc = ok && a == wv && b == step; }
    else if o == OP_SUB { vp_unported("sub inductions (getOptimizableIVOf)"); }
    else { if ind_descs[desc].kind == IK_PTR { vp_unported("pointer induction increments (getOptimizableIVOf)"); } }
    return if is_inc { w } else { -1 };
}

// optimizeLatchExitInductionUser
fn vpt_optimize_latch_exit_induction_user(opv: i32, ends: HMap&, pse: i32) -> i32 {
    // m_ExtractLastLaneOfLastPart
    let r = vp_def(opv);
    if !vpm_vpi_r(r, VPI_EXTRACT_LAST_LANE, 1) { return -1; }
    let r2 = vp_def(vp_op(r, 0));
    if !vpm_vpi_r(r2, VPI_EXTRACT_LAST_PART, 1) { return -1; }
    let incoming = vp_op(r2, 0);
    let w = vpt_optimizable_iv_of(incoming);
    if w < 0 { return -1; }
    let e = hm_get(ends, w as u64, -1) as i32;
    if incoming != vpr[w].def { return e; }
    vpb_set_before(r);
    let step = vp_op(w, 1);
    let sty = vpv[vpr[w].def].ty;
    if ty_is_int(sty) { return vp_val(vpb_sub(e, step, -1, "ind.escape", false, false)); }
    vp_unported("pointer / FP induction escape values");
    return -1;
}

// ---------------------------------------------------------------------------------------------
// dropPoisonGeneratingRecipes

fn vp_is_recipe_with_ir_flags(k: u8) -> bool {
    k == VPR_BLEND || k == VPR_INSTRUCTION || k == VPR_WIDEN || k == VPR_WIDEN_GEP || k == VPR_WIDEN_CALL || k == VPR_WIDEN_CAST ||
    k == VPR_WIDEN_INTRINSIC || k == VPR_WIDEN_MEM_INTRINSIC || k == VPR_REDUCTION || k == VPR_REDUCTION_EVL ||
    k == VPR_REPLICATE || k == VPR_VECTOR_END_POINTER || k == VPR_VECTOR_POINTER || k == VPR_WIDEN_CANONICAL_IV
}
// VPIRFlags::dropPoisonGeneratingFlags
fn vp_drop_poison_generating_flags(r: i32) {
    let ot = vpr[r].f.ot;
    if ot == VOT_OVERFLOWING || ot == VOT_TRUNC { vpr[r].f.nuw = false; vpr[r].f.nsw = false; }
    else if ot == VOT_DISJOINT { vpr[r].f.disjoint = false; }
    else if ot == VOT_EXACT { vpr[r].f.exact = false; }
    else if ot == VOT_GEP { vpr[r].f.gep = 0; }
    else if ot == VOT_FMF || ot == VOT_FCMP { vpr[r].f.fmf = vpr[r].f.fmf & ~(FMF_NNAN | FMF_NINF); }
    else if ot == VOT_NNEG { vpr[r].f.nneg = false; }
}
fn vpt_drop_poison_generating_recipes() {
    var visited = hm_new();
    fn collect(root: i32) {
        var wl: i32[>..<] = [];
        wl.push(root);
        while wl.len > 0 {
            var cur = wl.pop();
            if !ivd_set_add(visited, cur) { continue; }
            let k = vpr[cur].kind;
            if vp_is_widen_memory_kind(k) || k == VPR_INTERLEAVE || k == VPR_SCALAR_IV_STEPS || vp_is_header_phi_kind(k) { continue; }
            if vp_is_recipe_with_ir_flags(k) {
                if vpm_opcode(cur, true) == OP_OR as i32 && vpm_arity_ok(cur, 2) && vpr[cur].f.ot == VOT_DISJOINT && vpr[cur].f.disjoint {
                    vp_unported("dropPoisonGeneratingRecipes of a disjoint or");
                }
                vp_drop_poison_generating_flags(cur);
            }
            for k2 in vp_nops(cur) { let d = vp_def(vp_op(cur, k2)); if d >= 0 { wl.push(d); } }
        }
    }
    var bs: i32[>..<] = [];
    vp_depth_first(vp_header_bb(), false, bs);
    vp_only_basic(bs);
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 {
            let k = vpr[r].kind;
            if vp_is_widen_memory_kind(k) {
                let ad = vp_def(vp_op(r, 0));
                let mask = if vpr[r].masked { vp_op(r, vp_nops(r) - 1) } else { -1 };
                if mask >= 0 { vp_unported("dropPoisonGeneratingRecipes with masks"); }
                if ad >= 0 && vpr[r].consecutive && mask >= 0 { collect(ad); }
            } else if k == VPR_INTERLEAVE {
                vp_unported("dropPoisonGeneratingRecipes of interleave groups");
            }
            r = vpr[r].next;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// plan-building steps that need reductions / recurrences / groups / predication (loud until ported)

fn vpt_header_has_kind(kind: u8) -> bool {
    var phis: i32[>..<] = [];
    vp_block_phis(vp_header_bb(), phis);
    for p in phis { if vpr[p].kind == kind { return true; } }
    return false;
}
// adjustInLoopReductions: only out-of-loop (unordered) reductions are formed
fn vpt_create_in_loop_reduction_recipes(min_vf: i64) {
    var phis: i32[>..<] = [];
    vp_block_phis(vp_header_bb(), phis);
    for p in phis { if vpr[p].kind == VPR_REDUCTION_PHI && vpr[p].rdx_style != VRS_UNORDERED { vp_unported("in-loop reductions"); } }
}
fn vpt_adjust_first_order_recurrence_middle_users() { if vpt_header_has_kind(VPR_FIRST_ORDER_RECURRENCE_PHI) { vp_unported("fixed-order recurrences"); } }
fn vpt_optimize_find_iv_reductions() {}
fn vpt_handle_multi_use_reductions() -> bool { true }
fn vpt_handle_max_min_num_reductions() -> bool { true }
fn vpt_handle_find_last_reductions() -> bool { true }
fn vpt_create_partial_reductions() {}
fn vpt_convert_to_abstract_recipes() {}
// convertToStridedAccesses: only non-consecutive widened loads (gathers) are candidates
fn vpt_convert_to_strided_accesses() {
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 { if vpr[r].kind == VPR_WIDEN_LOAD && !vpr[r].consecutive { vp_unported("gathers (convertToStridedAccesses)"); } r = vpr[r].next; }
    }
}
fn vpt_hoist_predicated_loads() {}
fn vpt_sink_predicated_stores() {}
fn vpt_truncate_to_minimal_bitwidths() {}
fn vpt_narrow_interleave_groups() {}
fn vpt_materialize_header_mask() { if vpb[vp_vector_loop_region()].header_mask >= 0 { vp_unported("materializeHeaderMask"); } }

fn pred_inverse_vpt(p: i64) -> i64 {
    if p == 32 { return 33; } if p == 33 { return 32; }
    if p == 34 { return 37; } if p == 35 { return 36; } if p == 36 { return 35; } if p == 37 { return 34; }
    if p == 38 { return 41; } if p == 39 { return 40; } if p == 40 { return 39; } if p == 41 { return 38; }
    return p;
}
