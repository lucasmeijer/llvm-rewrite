// InstCombine's IRBuilder: IRBuilder<TargetFolder, IRBuilderInstCombineInserter> (llvm/include/llvm/IR/IRBuilder.h,
// llvm/lib/IR/IRBuilder.cpp, llvm/include/llvm/Analysis/TargetFolder.h, InstructionCombining.cpp's
// IRBuilderInstCombineInserter::InsertHelper).
//
// One global builder: insertion point (before an instruction, or the end of a block), current debug location,
// fast-math flags (FastMathFlagGuard = save/restore icb_fmf). Created instructions are inserted, named (the
// function's symbol table uniques the name), get the debug location, and are added to the deferred worklist.
// All icb_* functions return a value id: a folded constant or the new instruction.
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import autoupgrade;
import constfold;
import cfold;
import pm;
import instsimplify;
import ic;
import ic_negator;

var icb_pos: i32 = -1;     // insert before this instruction; -1 = at the end of icb_bb
var icb_bb: i32 = -1;
var icb_dl: i32 = -1;      // current debug location (!dbg md id)
var icb_fmf: u8 = 0;       // the builder's FastMathFlags
var ic_annot_src: i32 = -1;   // AnnotationMetadataSource

// Builder.SetInsertPoint(I) + SetCurrentDebugLocation(I->getDebugLoc())
fn icb_set_insert_point(i: i32) { icb_bb = inst_parent(i); icb_pos = i; icb_dl = inst_get_md(i, 0); }
// SetInsertPoint(I) only (IRBuilder::SetInsertPoint(Instruction*) also sets the debug location)
fn icb_set_insert_before(i: i32) { icb_set_insert_point(i); }
fn icb_set_insert_end(bb: i32) { icb_bb = bb; icb_pos = -1; }

fn aset_int(s: i32, kind: i64) -> u64 { let a = aset_find(s, kind); if a < 0 { 0 } else { attrs[a].i1 } }

// IRBuilderBase::Insert(I, Name)
fn icb_insert(iv: i32, name: const u8[:]) -> i32 {
    if icb_pos >= 0 { m2r_insert_before_adopting(iv, icb_pos); } else { block_append_inst(icb_bb, iv); }
    ic_register_name(iv);
    if name.len > 0 && vals[iv].ty != T_VOID { set_name(iv, name); }
    if ng_active {
        // the Negator's IRBuilderCallbackInserter: just record it
        ng_new.push(iv);
    } else {
        icw_add(iv);
        if inst_iid(iv) == IID_assume { ic_register_assumption(iv); }
        if ic_annot_src >= 0 { ic_copy_annotation_md(iv, ic_annot_src); }
    }
    // AddMetadataToInst: SetInstDebugLocation
    if icb_dl >= 0 { inst_set_md(iv, 0, icb_dl); }
    return iv;
}

// ---------------------------------------------------------------------------------------------
// Unattached instruction creation (BinaryOperator::Create, CastInst::Create, ...), for visitor results

fn ic_new_binop(o: i64, a: i32, b: i32) -> i32 { create_inst(o, vals[a].ty, [a, b]) }
fn ic_new_binop_flags(o: i64, a: i32, b: i32, fl: u8) -> i32 {
    let i = ic_new_binop(o, a, b);
    insts[inst_of(i)].flags = fl;
    return i;
}
fn ic_new_neg(v: i32) -> i32 { ic_new_binop(OP_SUB, c_null(vals[v].ty), v) }
fn ic_new_not(v: i32) -> i32 { ic_new_binop(OP_XOR, v, c_all_ones(vals[v].ty)) }
fn ic_new_cast(o: i64, v: i32, ty: i32) -> i32 { create_inst(o, ty, [v]) }
// CastInst::CreateZExtOrBitCast / CreateSExtOrBitCast / CreateTruncOrBitCast
fn ic_new_zext_or_bitcast(v: i32, ty: i32) -> i32 {
    if ty_scalar_bits(vals[v].ty) == ty_scalar_bits(ty) { return ic_new_cast(OP_BITCAST, v, ty); }
    return ic_new_cast(OP_ZEXT, v, ty);
}
fn ic_new_sext_or_bitcast(v: i32, ty: i32) -> i32 {
    if ty_scalar_bits(vals[v].ty) == ty_scalar_bits(ty) { return ic_new_cast(OP_BITCAST, v, ty); }
    return ic_new_cast(OP_SEXT, v, ty);
}
fn ic_new_icmp(p: i64, a: i32, b: i32) -> i32 {
    let i = create_inst(OP_ICMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(i)].pred = p as u8;
    return i;
}
fn ic_new_select(c: i32, t: i32, f: i32) -> i32 { create_inst(OP_SELECT, vals[t].ty, [c, t, f]) }
// SelectInst::Create(C, S1, S2, Name, InsertBefore, MDFrom): copies !prof and !unpredictable from MDFrom
fn ic_new_select_md(c: i32, t: i32, f: i32, mdfrom: i32) -> i32 {
    let s = ic_new_select(c, t, f);
    if mdfrom >= 0 { icb_copy_select_md(s, mdfrom); }
    return s;
}
fn icb_copy_select_md(s: i32, from: i32) {
    let kp = md_kind_id("prof");
    let ku = md_kind_id("unpredictable");
    let p = inst_get_md(from, kp);
    let u = inst_get_md(from, ku);
    if p >= 0 { inst_set_md(s, kp, p); }
    if u >= 0 { inst_set_md(s, ku, u); }
}
// createSelectInstWithUnknownProfile: setExplicitlyUnknownBranchWeightsIfProfiled
fn ic_new_select_unknown_prof(c: i32, t: i32, f: i32) -> i32 {
    if ic_fn >= 0 && ic_fn_has_entry_count(ic_fn) { ic_not_ported("explicitly unknown branch weights (function with profile)"); }
    return ic_new_select(c, t, f);
}
fn ic_fn_has_entry_count(fv: i32) -> bool {
    let g = glob_of(fv);
    let k = md_kind_id("prof");
    for j in globs[g].nmd { if md_att[globs[g].md + 2 * j] == k { return true; } }
    return false;
}

// Intrinsic call (unattached): CallInst::Create(Intrinsic::getOrInsertDeclaration(M, ID, Types), Args)
fn ic_new_intrinsic(id: i64, ov: const i32[:], argsv: const i32[:]) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(iv)].ty2 = fty;
    return iv;
}

// ---------------------------------------------------------------------------------------------
// TargetFolder

fn tf_fold(c: i32) -> i32 { cf_fold_constant(c) }

fn tf_binop(o: i64, a: i32, b: i32, fl: u8) -> i32 {
    if !is_constant(a) || !is_constant(b) { return -1; }
    if is_desirable_binop(o) { return tf_fold(ce_binop(o, a, b, fl)); }
    return cf_fold_binop_operands(o, a, b);
}

// ---------------------------------------------------------------------------------------------
// Create* (each returns a value: folded constant or the inserted instruction)

fn icb_binop_fl(o: i64, a: i32, b: i32, name: const u8[:], fl: u8) -> i32 {
    let f = tf_binop(o, a, b, fl);
    if f >= 0 { return f; }
    let i = ic_new_binop_flags(o, a, b, fl);
    if is_fp_math_operator(i) { insts[inst_of(i)].fmf = icb_fmf; }
    return icb_insert(i, name);
}
fn nw_flags(nuw: bool, nsw: bool) -> u8 { var f: u8 = 0; if nuw { f |= FL_NUW; } if nsw { f |= FL_NSW; } return f; }
fn ex_flags(exact: bool) -> u8 { if exact { FL_EXACT } else { 0 } }
// CreateBinOp(Opc, LHS, RHS, Name): no wrap flags
fn icb_binop(o: i64, a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(o, a, b, name, 0) }
fn icb_add(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_ADD, a, b, name, 0) }
fn icb_add_nw(a: i32, b: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 { icb_binop_fl(OP_ADD, a, b, name, nw_flags(nuw, nsw)) }
fn icb_sub(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_SUB, a, b, name, 0) }
fn icb_sub_nw(a: i32, b: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 { icb_binop_fl(OP_SUB, a, b, name, nw_flags(nuw, nsw)) }
fn icb_mul(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_MUL, a, b, name, 0) }
fn icb_mul_nw(a: i32, b: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 { icb_binop_fl(OP_MUL, a, b, name, nw_flags(nuw, nsw)) }
fn icb_shl(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_SHL, a, b, name, 0) }
fn icb_shl_nw(a: i32, b: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 { icb_binop_fl(OP_SHL, a, b, name, nw_flags(nuw, nsw)) }
fn icb_shl_k(a: i32, k: u64, name: const u8[:]) -> i32 { icb_shl(a, c_int_ty(vals[a].ty, k), name) }
fn icb_lshr(a: i32, b: i32, name: const u8[:], exact: bool) -> i32 { icb_binop_fl(OP_LSHR, a, b, name, ex_flags(exact)) }
fn icb_ashr(a: i32, b: i32, name: const u8[:], exact: bool) -> i32 { icb_binop_fl(OP_ASHR, a, b, name, ex_flags(exact)) }
fn icb_udiv(a: i32, b: i32, name: const u8[:], exact: bool) -> i32 { icb_binop_fl(OP_UDIV, a, b, name, ex_flags(exact)) }
fn icb_sdiv(a: i32, b: i32, name: const u8[:], exact: bool) -> i32 { icb_binop_fl(OP_SDIV, a, b, name, ex_flags(exact)) }
fn icb_urem(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_UREM, a, b, name, 0) }
fn icb_srem(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_SREM, a, b, name, 0) }
fn icb_and(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_AND, a, b, name, 0) }
fn icb_or(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_OR, a, b, name, 0) }
fn icb_disjoint_or(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_OR, a, b, name, FL_DISJOINT) }
fn icb_xor(a: i32, b: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_XOR, a, b, name, 0) }
fn icb_neg(v: i32, name: const u8[:], nsw: bool) -> i32 { icb_binop_fl(OP_SUB, c_null(vals[v].ty), v, name, nw_flags(false, nsw)) }
fn icb_not(v: i32, name: const u8[:]) -> i32 { icb_binop_fl(OP_XOR, v, c_all_ones(vals[v].ty), name, 0) }

// CreateICmp(P, LHS, RHS, Name)
fn icb_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let f = cf_fold_cmp_operands(p, a, b, -1);
        if f >= 0 { return f; }
    }
    return icb_insert(ic_new_icmp(p, a, b), name);
}
fn icb_is_null(v: i32, name: const u8[:]) -> i32 { icb_icmp(32, v, c_null(vals[v].ty), name) }
fn icb_is_not_null(v: i32, name: const u8[:]) -> i32 { icb_icmp(33, v, c_null(vals[v].ty), name) }

// CreateSelect(C, True, False, Name, MDFrom)
fn icb_select(c: i32, t: i32, f: i32, name: const u8[:], mdfrom: i32) -> i32 {
    if is_constant(c) && is_constant(t) && is_constant(f) {
        let r = cf_select(c, t, f);
        if r >= 0 { return r; }
    }
    let s = ic_new_select(c, t, f);
    if mdfrom >= 0 { icb_copy_select_md(s, mdfrom); }
    if is_fp_math_operator(s) { insts[inst_of(s)].fmf = icb_fmf; }
    return icb_insert(s, name);
}
// CreateLogicalAnd / CreateLogicalOr
fn icb_logical_and(a: i32, b: i32, name: const u8[:]) -> i32 { icb_select(a, b, c_null(vals[b].ty), name, -1) }
fn icb_logical_or(a: i32, b: i32, name: const u8[:]) -> i32 { icb_select(a, c_all_ones(vals[b].ty), b, name, -1) }

// CreateCast(Op, V, DestTy, Name)
fn icb_cast(o: i64, v: i32, ty: i32, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    if is_constant(v) {
        let f = cf_fold_cast_operand(o, v, ty);
        if f >= 0 { return f; }
    }
    return icb_insert(ic_new_cast(o, v, ty), name);
}
fn icb_zext(v: i32, ty: i32, name: const u8[:]) -> i32 { icb_cast(OP_ZEXT, v, ty, name) }
fn icb_sext(v: i32, ty: i32, name: const u8[:]) -> i32 { icb_cast(OP_SEXT, v, ty, name) }
fn icb_trunc(v: i32, ty: i32, name: const u8[:]) -> i32 { icb_cast(OP_TRUNC, v, ty, name) }
// CreateTrunc(V, DestTy, Name, IsNUW, IsNSW)
fn icb_trunc_nw(v: i32, ty: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 {
    if vals[v].ty == ty { return v; }
    if is_constant(v) {
        let f = cf_fold_cast_operand(OP_TRUNC, v, ty);
        if f >= 0 { return f; }
    }
    let i = ic_new_cast(OP_TRUNC, v, ty);
    insts[inst_of(i)].flags = nw_flags(nuw, nsw);
    return icb_insert(i, name);
}
// CreateZExt(V, DestTy, Name, IsNonNeg)
fn icb_zext_nneg(v: i32, ty: i32, name: const u8[:], nneg: bool) -> i32 {
    if vals[v].ty == ty { return v; }
    if is_constant(v) {
        let f = cf_fold_cast_operand(OP_ZEXT, v, ty);
        if f >= 0 { return f; }
    }
    let i = ic_new_cast(OP_ZEXT, v, ty);
    if nneg { insts[inst_of(i)].flags = FL_NNEG; }
    return icb_insert(i, name);
}
fn icb_zext_or_trunc(v: i32, ty: i32, name: const u8[:]) -> i32 {
    let vb = ty_scalar_bits(vals[v].ty);
    let db = ty_scalar_bits(ty);
    if vb < db { return icb_zext(v, ty, name); }
    if vb > db { return icb_trunc(v, ty, name); }
    return v;
}
fn icb_sext_or_trunc(v: i32, ty: i32, name: const u8[:]) -> i32 {
    let vb = ty_scalar_bits(vals[v].ty);
    let db = ty_scalar_bits(ty);
    if vb < db { return icb_sext(v, ty, name); }
    if vb > db { return icb_trunc(v, ty, name); }
    return v;
}
fn icb_freeze(v: i32, name: const u8[:]) -> i32 { icb_insert(create_inst(OP_FREEZE, vals[v].ty, [v]), name) }

// TargetFolder::FoldIntrinsic: ConstantFoldIntrinsic when every operand is a constant
fn tf_intrinsic(id: i64, argsv: const i32[:], rty: i32) -> i32 {
    for a in argsv { if !is_constant(a) { return -1; } }
    let mark = is_ops.len;
    for a in argsv { is_ops.push(a); }
    var cx = icb_pos;
    if cx < 0 { cx = block_last(icb_bb); }
    var r: i32 = -1;
    if ty_kind(rty) == TK_FVEC { r = cf_fold_fixed_vector_call(cx, id as i32, rty, mark, argsv.len); }
    else if ty_kind(rty) == TK_SVEC { ic_not_ported("folding a scalable vector intrinsic in the builder"); }
    else { r = cf_fold_scalar_call(cx, id as i32, rty, mark, argsv.len); }
    is_ops.resize(mark);
    return r;
}
// CreateIntrinsic(ID, OverloadTypes, Args, FMFSource, Name)
fn icb_intrinsic(id: i64, ov: const i32[:], argsv: const i32[:], name: const u8[:]) -> i32 {
    let rty = ty_fn_ret(intr_get_type(id, ov));
    let f = tf_intrinsic(id, argsv, rty);
    if f >= 0 { return f; }
    let c = ic_new_intrinsic(id, ov, argsv);
    if is_fp_math_operator(c) { insts[inst_of(c)].fmf = icb_fmf; }
    return icb_insert(c, name);
}
// CreateBinaryIntrinsic(ID, LHS, RHS, FMFSource, Name): overloaded on the operand type
fn icb_binary_intrinsic(id: i64, a: i32, b: i32, name: const u8[:]) -> i32 { icb_intrinsic(id, [vals[a].ty], [a, b], name) }
fn icb_unary_intrinsic(id: i64, a: i32, name: const u8[:]) -> i32 { icb_intrinsic(id, [vals[a].ty], [a], name) }
