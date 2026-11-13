// VPExpressionRecipe (abstract in-loop reduction expressions: reduce(ext), reduce(mul), reduce(mul(ext, ext)), ...)
// and VPlanTransforms::convertToAbstractRecipes.
// Ported from llvm/lib/Transforms/Vectorize/VPlanRecipes.cpp (VPExpressionRecipe), VPlan.h (its constructors and
// clone) and VPlanTransforms.cpp (tryToMatchAndCreateExtendedReduction, tryToMatchAndCreateMulAccumulateReduction,
// tryToCreateAbstractReductionRecipe, convertToAbstractRecipes), LLVM 23.1.5.
//
// The member recipes stay rows of the plan, unlinked from any block (`expr_recipes`, possibly with duplicates);
// LiveInPlaceholders are symbolic values (`expr_placeholders`), one per operand of the expression recipe.

VP_EXPR_EXTENDED_REDUCTION :: 0;
VP_EXPR_NEGATED_EXTENDED_REDUCTION :: 1;
VP_EXPR_EXT_MUL_ACC_REDUCTION :: 2;
VP_EXPR_MUL_ACC_REDUCTION :: 3;
VP_EXPR_EXT_NEGATED_MUL_ACC_REDUCTION :: 4;

// VPExpressionRecipe(ExpressionTypes, ArrayRef<VPSingleDefRecipe *>)
vp_new_expression :: (type: u8, recipes: [] Vp_Rec) -> Vp_Rec {
    assert(recipes.count > 0, "Nothing to combine?");
    last := recipes[recipes.count - 1];
    r := vp_new_single_def(.EXPRESSION, .[], vp_scalar_type(vp_op(last, 0)));
    vr(r).expr_type = type;
    for recipes array_add(*vr(r).expr_recipes, it);
    in_set :: (recipes: [] Vp_Rec, u: Vp_Rec) -> bool { for recipes if it == u return true; return false; }
    for < x: recipes {
        if x != last {
            outside := false;
            for u: vv(vr(x).def).users if !in_set(recipes, u) { outside = true; break; }
            if outside {
                copy := vp_clone(x);
                Ctx :: struct { recipes: [] Vp_Rec; }
                ctx := Ctx.{recipes};
                not_in :: (u: Vp_Rec, idx: s64, data: *void) -> bool { c := cast(*Ctx) data; return !in_set(c.recipes, u); }
                vp_replace_uses_with_if(vr(x).def, vr(copy).def, not_in, *ctx);
                vp_insert_before(copy, x);
            }
        }
        if vr(x).parent != NONE vp_remove_from_parent(x);
    }
    for x: recipes {
        for k: 0..vp_nops(x)-1 {
            o := vp_op(x, k);
            d := vp_def(o);
            if d != NONE && in_set(recipes, d) continue;
            vp_add_operand(r, o);
            ph := vp_new_symbolic(vp_scalar_type(o));
            array_add(*vr(r).expr_placeholders, ph);
        }
    }
    for x: recipes for k: 0..vp_nops(r)-1 vp_replace_uses_of_with(x, vp_op(r, k), vr(r).expr_placeholders[k]);
    return r;
}

// VPExpressionRecipe::clone
vp_clone_expression :: (r: Vp_Rec) -> Vp_Rec {
    olds := vr(r).expr_recipes;
    assert(olds.count > 0, "empty expressions should be removed");
    news: [..] Vp_Rec; news.allocator = temp;
    for olds array_add(*news, vp_clone(it));
    for n: news {
        for o, idx: olds vp_replace_uses_of_with(n, vr(o).def, vr(news[idx]).def);
        for ph, idx: vr(r).expr_placeholders vp_replace_uses_of_with(n, ph, vp_op(r, idx));
    }
    return vp_new_expression(vr(r).expr_type, news);
}

// VPExpressionRecipe::decompose: put the member recipes back before the expression (the caller erases it)
vp_decompose_expression :: (r: Vp_Rec) {
    for x: vr(r).expr_recipes if vr(x).parent == NONE vp_insert_before(x, r);
    for k: 0..vp_nops(r)-1 vp_rauw(vr(r).expr_placeholders[k], vp_op(r, k));
    rs := vr(r).expr_recipes;
    vp_rauw(vr(r).def, vr(rs[rs.count - 1]).def);
    vr(r).expr_recipes.count = 0;
}

vp_expression_reduction :: (r: Vp_Rec) -> Vp_Rec { rs := vr(r).expr_recipes; return rs[rs.count - 1]; }
// VPExpressionRecipe::getVFScaleFactor
vp_expression_vf_scale_factor :: (r: Vp_Rec) -> u32 {
    red := vp_expression_reduction(r);
    if vr(red).kind == .REDUCTION return vr(red).rdx_scale;
    return 1;
}
// VPExpressionRecipe::mayReadOrWriteMemory
vp_expression_may_read_or_write_memory :: (r: Vp_Rec) -> bool {
    for vr(r).expr_recipes if vp_may_read_from_memory(it) || vp_may_write_to_memory(it) return true;
    return false;
}
// VPExpressionRecipe::isVectorToScalar
vp_expression_is_vector_to_scalar :: (r: Vp_Rec) -> bool {
    red := vp_expression_reduction(r);
    return vr(red).kind == .REDUCTION && vr(red).rdx_scale <= 1;
}

// VPExpressionRecipe::computeCost (partial reductions are never formed on X86)
vp_expression_cost :: (c: *Vp_Cost_Ctx, r: Vp_Rec, vf: Ec) -> Cost {
    red_ty := vp_scalar_type(vr(r).def);
    src_vec_ty := lv_to_vector_ty(vp_scalar_type(vp_op(r, 0)), vf);
    red := vp_expression_reduction(r);
    assert(vr(red).rdx_scale <= 1, "partial reductions are not formed on X86");
    opc := rk_opcode(vr(red).rdx_kind);
    rs := vr(r).expr_recipes;
    if vr(r).expr_type == {
        case VP_EXPR_NEGATED_EXTENDED_REDUCTION; #through;
        case VP_EXPR_EXTENDED_REDUCTION;
            if vr(r).expr_type == VP_EXPR_NEGATED_EXTENDED_REDUCTION opc = ifx opc == .ADD then Opcode.SUB else .FSUB;
            if is_fp_type(red_ty) return COST_INVALID;
            ext := rs[0];
            return lcv(tti_extended_reduction_cost(c.tti, opc, vr(ext).opcode == vp_opc(.ZEXT), red_ty, src_vec_ty, false, 0, c.kind));
        case VP_EXPR_MUL_ACC_REDUCTION;
            return lcv(tti_mul_acc_reduction_cost(c.tti, false, opc, red_ty, src_vec_ty, c.kind));
        case VP_EXPR_EXT_NEGATED_MUL_ACC_REDUCTION; #through;
        case VP_EXPR_EXT_MUL_ACC_REDUCTION;
            if vr(r).expr_type == VP_EXPR_EXT_NEGATED_MUL_ACC_REDUCTION {
                if opc == .ADD opc = .SUB; else if opc == .FADD opc = .FSUB;
                else fatal("internal: Unsupported opcode for ExtNegatedMulAccReduction");
            }
            assert(opc != .FSUB, "Only integer types are supported");
            return lcv(tti_mul_acc_reduction_cost(c.tti, vr(rs[0]).opcode == vp_opc(.ZEXT), opc, red_ty, src_vec_ty, c.kind));
    }
    fatal("internal: Unknown VPExpressionRecipe::ExpressionTypes enum");
    return COST_INVALID;
}

// ---------------------------------------------------------------- convertToAbstractRecipes

vpx_is_widen_cast_ext :: (v: Vp_Val) -> (bool, Vp_Rec) {   // m_Isa<VPWidenCastRecipe>(m_ZExtOrSExt(...))
    d := vp_def(v);
    if d == NONE || vr(d).kind != .WIDEN_CAST return false, NONE;
    if vr(d).opcode != vp_opc(.ZEXT) && vr(d).opcode != vp_opc(.SEXT) return false, NONE;
    return true, d;
}
vpx_widen_cast_or_none :: (v: Vp_Val) -> Vp_Rec { d := vp_def(v); if d != NONE && vr(d).kind == .WIDEN_CAST return d; return NONE; }
// m_ZExtOrSExt on any recipe kind the cast matchers accept
vpx_match_ext :: (v: Vp_Val) -> (bool, Vp_Val) {
    ok, a := vpm_unary(v, vp_opc(.ZEXT));
    if ok return ok, a;
    ok2, b := vpm_unary(v, vp_opc(.SEXT));
    return ok2, b;
}

// tryToMatchAndCreateExtendedReduction
vpx_try_extended_reduction :: (red: Vp_Rec, c: *Vp_Cost_Ctx, range: *Vf_Range) -> Vp_Rec {
    red_ty := vp_scalar_type(vr(red).def);
    vec_op := vp_op(red, 1);
    assert(vr(red).rdx_scale <= 1, "This path does not support partial reductions");
    ok, ext := vpx_is_widen_cast_ext(vec_op);
    if !ok return NONE;
    Ctx :: struct { c: *Vp_Cost_Ctx; red: Vp_Rec; ext: Vp_Rec; opc: Opcode; is_zext: bool; src_ty: Type_Id; red_ty: Type_Id; }
    ctx := Ctx.{c, red, ext, rk_opcode(vr(red).rdx_kind), vr(ext).opcode == vp_opc(.ZEXT), vp_scalar_type(vp_op(ext, 0)), red_ty};
    pred :: (vf: Ec, data: *void) -> bool {
        x := cast(*Ctx) data;
        src_vec_ty := lv_to_vector_ty(x.src_ty, vf);
        ext_cost := vp_compute_cost(x.c, x.ext, vf);
        red_cost := vp_compute_cost(x.c, x.red, vf);
        assert(!is_fp_type(x.red_ty), "getExtendedReductionCost only supports integer types");
        ext_red := lcv(tti_extended_reduction_cost(x.c.tti, x.opc, x.is_zext, x.red_ty, src_vec_ty, true, vp_fmf_or_none(x.red), x.c.kind));
        return cost_valid(ext_red) && ext_red < lc_add(ext_cost, red_cost);
    }
    if !lvp_decision_and_clamp_range(range, pred, *ctx) return NONE;
    return vp_new_expression(VP_EXPR_EXTENDED_REDUCTION, .[ext, red]);
}

// tryToMatchAndCreateMulAccumulateReduction
vpx_try_mul_acc_reduction :: (red: Vp_Rec, c: *Vp_Cost_Ctx, range: *Vf_Range) -> Vp_Rec {
    opc := rk_opcode(vr(red).rdx_kind);
    if opc != .ADD && opc != .SUB && opc != .FADD return NONE;
    assert(vr(red).rdx_scale <= 1, "This path does not support partial reductions");
    red_ty := vp_scalar_type(vr(red).def);
    Ctx :: struct { c: *Vp_Cost_Ctx; red: Vp_Rec; opc: Opcode; red_ty: Type_Id; mul: Vp_Rec; ext0: Vp_Rec; ext1: Vp_Rec; outer: Vp_Rec; }
    valid_and_clamp :: (c: *Vp_Cost_Ctx, red: Vp_Rec, opc: Opcode, red_ty: Type_Id, mul: Vp_Rec, ext0: Vp_Rec, ext1: Vp_Rec, outer: Vp_Rec, range: *Vf_Range) -> bool {
        ctx := Ctx.{c, red, opc, red_ty, mul, ext0, ext1, outer};
        pred :: (vf: Ec, data: *void) -> bool {
            x := cast(*Ctx) data;
            src_ty := ifx x.ext0 != NONE then vp_scalar_type(vp_op(x.ext0, 0)) else x.red_ty;
            if x.ext0 != NONE && x.ext1 != NONE && (vr(x.ext0).opcode != vr(x.ext1).opcode || vr(x.ext0).opcode == vp_opc(.FPEXT)) return false;
            is_zext := x.ext0 == NONE || vr(x.ext0).opcode == vp_opc(.ZEXT);
            src_vec_ty := lv_to_vector_ty(src_ty, vf);
            mul_acc := lcv(tti_mul_acc_reduction_cost(x.c.tti, is_zext, x.opc, x.red_ty, src_vec_ty, x.c.kind));
            mul_cost := vp_compute_cost(x.c, x.mul, vf);
            red_cost := vp_compute_cost(x.c, x.red, vf);
            ext_cost: Lc = 0;
            if x.ext0 != NONE ext_cost = lc_add(ext_cost, vp_compute_cost(x.c, x.ext0, vf));
            if x.ext1 != NONE ext_cost = lc_add(ext_cost, vp_compute_cost(x.c, x.ext1, vf));
            if x.outer != NONE ext_cost = lc_add(ext_cost, vp_compute_cost(x.c, x.outer, vf));
            return cost_valid(mul_acc) && mul_acc < lc_add(lc_add(ext_cost, mul_cost), red_cost);
        }
        return lvp_decision_and_clamp_range(range, pred, *ctx);
    }
    // ExtendAndReplaceConstantOp: reduce.add(mul(ext, const)) -> reduce.add(mul(ext, ext(trunc(const))))
    extend_and_replace_constant_op :: (ext_a: Vp_Rec, ext_b: *Vp_Rec, val_b: *Vp_Val, mul: Vp_Rec) {
        if ext_a == NONE || ext_b.* != NONE || !vp_is_ir_value(val_b.*) return;
        narrow_ty := vp_scalar_type(vp_op(ext_a, 0));
        ext_opc := vp_ir_opcode(vr(ext_a).opcode);
        if !vp_is_constant_int(val_b.*) return;
        k := vp_const_int_value(val_b.*);
        if type_bits(narrow_ty) > k.bits fatal("loop-vectorize: canConstantBeExtended with a narrow type wider than the constant (APInt::trunc assertion in LLVM)");
        tr := ap_trunc(k, type_bits(narrow_ty));
        ext := ifx ext_opc == .SEXT then ap_sext(tr, k.bits) else ap_zext(tr, k.bits);
        if !ap_eq(ext, k) return;
        b := vpb_before(mul);
        trunc := vpb_widen_cast(*b, .TRUNC, val_b.*, narrow_ty);
        wide_ty := vp_scalar_type(vr(ext_a).def);
        nb := vpb_widen_cast(*b, ext_opc, vr(trunc).def, wide_ty);
        ext_b.* = nb;
        val_b.* = vr(nb).def;
        vp_set_operand(mul, 1, vr(nb).def);
    }
    vec_op := vp_op(red, 1);
    sub: Vp_Rec = NONE;
    if is_fp_type(red_ty) return NONE;
    {
        ok, z, tmp := vpm_binary(vec_op, vp_opc(.SUB));
        if ok && vpm_zero_int(z) { sub = vp_def(vec_op); vec_op = tmp; }
    }
    {
        ok, a, b := vpm_binary(vec_op, vp_opc(.MUL));
        if ok {
            ra := vpx_widen_cast_or_none(a);
            rb := vpx_widen_cast_or_none(b);
            mul := vp_def(vec_op);
            assert(vr(mul).kind == .WIDEN, "expected a VPWidenRecipe mul");
            extend_and_replace_constant_op(ra, *rb, *b, mul);
            if ra != NONE && rb != NONE && vpx_match_ext(vr(ra).def) && vpx_match_ext(vr(rb).def) &&
               valid_and_clamp(c, red, opc, red_ty, mul, ra, rb, NONE, range) {
                if sub != NONE return vp_new_expression(VP_EXPR_EXT_NEGATED_MUL_ACC_REDUCTION, .[ra, rb, mul, sub, red]);
                return vp_new_expression(VP_EXPR_EXT_MUL_ACC_REDUCTION, .[ra, rb, mul, red]);
            }
            if sub == NONE && valid_and_clamp(c, red, opc, red_ty, mul, NONE, NONE, NONE, range)
                return vp_new_expression(VP_EXPR_MUL_ACC_REDUCTION, .[mul, red]);
        }
    }
    if sub != NONE return NONE;
    {
        ok, inner := vpx_match_ext(vec_op);
        okm, a, b := false, cast(Vp_Val) NONE, cast(Vp_Val) NONE;
        if ok okm, a, b = vpm_binary(inner, vp_opc(.MUL));
        if okm {
            ext := vp_def(vec_op);
            assert(vr(ext).kind == .WIDEN_CAST, "expected a VPWidenCastRecipe");
            mul := vp_def(vp_op(ext, 0));
            assert(vr(mul).kind == .WIDEN, "expected a VPWidenRecipe mul");
            ext0 := vpx_widen_cast_or_none(a);
            ext1 := vpx_widen_cast_or_none(b);
            extend_and_replace_constant_op(ext0, *ext1, *b, mul);
            if ext0 != NONE && ext1 != NONE && (vr(ext).opcode == vr(ext0).opcode || ext0 == ext1) && vr(ext0).opcode == vr(ext1).opcode &&
               valid_and_clamp(c, red, opc, red_ty, mul, ext0, ext1, ext, range) && vp_has_one_use(vr(mul).def) {
                wide_ty := vp_scalar_type(vr(ext).def);
                n0 := vp_new_widen_cast(vp_ir_opcode(vr(ext0).opcode), vp_op(ext0, 0), wide_ty, NONE, vr(ext0).flags, vr(ext0).md, vr(ext0).dl);
                vp_insert_before(n0, ext0);
                n1 := n0;
                if ext0 != ext1 {
                    n1 = vp_new_widen_cast(vp_ir_opcode(vr(ext1).opcode), vp_op(ext1, 0), wide_ty, NONE, vr(ext1).flags, vr(ext1).md, vr(ext1).dl);
                    vp_insert_before(n1, ext1);
                }
                nm := vp_clone(mul);   // cloneWithOperands({NewExt0, NewExt1})
                vp_set_operand(nm, 0, vr(n0).def);
                vp_set_operand(nm, 1, vr(n1).def);
                vv(vr(nm).def).ty = vp_compute_scalar_type_for_instruction(vr(nm).opcode, vr(nm).ops);
                vp_insert_before(nm, mul);
                vp_rauw(vr(ext).def, vr(nm).def);
                vp_erase_recipe(ext);
                vp_erase_recipe(mul);
                return vp_new_expression(VP_EXPR_EXT_MUL_ACC_REDUCTION, .[n0, n1, nm, red]);
            }
        }
    }
    return NONE;
}

// VPlanTransforms::convertToAbstractRecipes
vp_convert_to_abstract_recipes :: (lp: *Lv_Planner, range: *Vf_Range) {
    c: Vp_Cost_Ctx;
    vpc_init(*c, lp);
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vp_vector_loop_region())) {
        for red: vp_block_recipes(bb) {
            if vr(red).kind != .REDUCTION && vr(red).kind != .REDUCTION_EVL continue;
            assert(vr(red).rdx_scale <= 1, "This path does not support partial reductions");
            ip := vr(red).next;
            parent := vr(red).parent;
            abs := vpx_try_mul_acc_reduction(red, *c, range);
            if abs == NONE abs = vpx_try_extended_reduction(red, *c, range);
            if abs == NONE continue;
            vp_insert_recipe(abs, parent, ip);
            vp_rauw(vr(red).def, vr(abs).def);
        }
    }
}
