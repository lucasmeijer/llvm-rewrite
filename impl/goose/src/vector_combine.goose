// VectorCombine, part 1: port of llvm/lib/Transforms/Vectorize/VectorCombine.cpp (the pass state, the
// InstructionWorklist, replaceValue / eraseInstruction, the IRBuilder<InstSimplifyFolder>, and the folds from
// vectorizeLoadInsert to foldConcatOfBoolMasks in file order). Part 2 (vector_combine2.goose) has the shuffle and
// reduction folds and the driver (VectorCombine::run, VectorCombinePass::run).
//
// The pass's Builder is IRBuilder<InstSimplifyFolder> with SimplifyQuery(DL); the folds that make a local
// `IRBuilder<> Builder(I)` switch the same global builder to ConstantFolder mode (vcb_cf) after setting its
// insertion point: every fold starts from FoldInst's SetInsertPoint(&I), so the member builder's state never
// survives a local one. Cost queries go through tti_vec.goose (X86TTIImpl or NoTTIImpl).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import gen_attrs;
import intrinsics;
import autoupgrade;
import constfold;
import cfold;
import datalayout;
import apint;
import pm;
import vt;
import knownbits;
import poison;
import constrange;
import instsimplify;
import local;
import salvage;
import loads;
import speculate;
import memloc;
import aa;
import domtree;
import domcond;
import flags;
import sroa;
import tti;
import tti_x86;
import tti_vec;
import vecutils;

// ---------------------------------------------------------------- state

var vc_fv: i32 = -1;
var vc_kind: i64 = 0;              // CostKind: TCK_RecipThroughput, or TCK_CodeSize for optsize functions
var vc_early_only: bool = false;   // TryEarlyFoldsOnly
var vc_next: i32 = -1;             // NextInst
var vc_wl: i32[>..<];              // InstructionWorklist::Worklist (-1 = a removed entry)
// WorklistMap: VM_PASS0 (value -> index in vc_wl); eraseInstruction's Visited: VS_PASS1; fold-local sets: VS_PASS0.

fn vc_max_scan() -> i64 { flag_int("vector-combine-max-scan-instrs", 30) }
fn vc_not_ported(what: const u8[:]) { fatal(str("VectorCombine: ", what, " is not ported yet")); }

let VC_EQ: i64 = 32;
let VC_NE: i64 = 33;
let VC_UGT: i64 = 34;
let VC_UGE: i64 = 35;
let VC_ULT: i64 = 36;
let VC_ULE: i64 = 37;
let VC_SGT: i64 = 38;
let VC_SGE: i64 = 39;
let VC_SLT: i64 = 40;
let VC_SLE: i64 = 41;

// ---------------------------------------------------------------- InstructionWorklist

fn vcw_push(i: i32) {
    if vm_has(VM_PASS0, i) { return; }
    vm_set(VM_PASS0, i, vc_wl.len);
    vc_wl.push(i);
}
fn vcw_push_value(v: i32) { if v >= 0 && is_inst(v) { vcw_push(v); } }
fn vcw_remove(i: i32) {
    if !vm_has(VM_PASS0, i) { return; }
    let k = vm_get(VM_PASS0, i, -1);
    vc_wl[k] = -1;
    vm_del(VM_PASS0, i);
}
fn vcw_remove_one() -> i32 {
    let i = vc_wl.pop();
    if i >= 0 { vm_del(VM_PASS0, i); }
    return i;
}
fn vcw_push_users(i: i32) {
    var u = vals[i].first_use;
    while u >= 0 { vcw_push(uses[u].user); u = uses[u].next; }
}

// Value::takeName(V)
fn vc_take_name(dst: i32, src: i32) {
    if dst == src { return; }
    if vals[dst].name >= 0 { set_name(dst, ""); }
    if vals[src].name < 0 { return; }
    var buf: u8[>..] = [];
    buf.append(sbytes(vals[src].name));
    set_name(src, "");
    if is_constant(dst) { return; }
    set_name(dst, buf);
}

// replaceValue(Old, New, Erase)
fn vc_replace(old: i32, nw: i32, erase: bool) {
    rauw(old, nw);
    if is_inst(nw) {
        vc_take_name(nw, old);
        vcw_push_users(nw);
        vcw_push(nw);
    }
    if erase && is_instruction_trivially_dead(old) { vc_erase(old); } else { vcw_push(old); }
}

// RecursivelyDeleteTriviallyDeadInstructions(V, TLI = nullptr, MSSAU = nullptr, callback) with
// eraseInstruction's AboutToDeleteCallback
fn vc_recursively_delete(v: i32) -> bool {
    if !is_inst(v) || !is_instruction_trivially_dead(v) { return false; }
    var dead: i32[>..<] = [];
    dead.push(v);
    while dead.len > 0 {
        let i = dead.pop();
        if is_dead(i) { continue; }
        salvage_debug_info(i);
        vcw_remove(i);
        if i == vc_next { vc_next = inst_next(i); }
        vs_add(VS_PASS1, i);
        for k in nops(i) {
            let o = op(i, k);
            set_op(i, k, -1);
            if o < 0 || vals[o].first_use >= 0 { continue; }
            if is_inst(o) && is_instruction_trivially_dead(o) { dead.push(o); }
        }
        inst_erase_from_parent(i);
    }
    return true;
}

// eraseInstruction(I)
fn vc_erase(i: i32) {
    var opsv: i32[>..<] = [];
    for k in nops(i) { opsv.push(op(i, k)); }
    vcw_remove(i);
    inst_erase_from_parent(i);
    vs_clear(VS_PASS1);
    for o in opsv {
        if o < 0 || vs_has(VS_PASS1, o) { continue; }
        if is_inst(o) {
            if vc_recursively_delete(o) { continue; }
            vcw_push_users(o);
            vcw_push(o);
        }
    }
}

// ---------------------------------------------------------------- the builder

var vcb_bb: i32 = -1;
var vcb_pos: i32 = -1;         // insert before this instruction; -1 = the end of vcb_bb
var vcb_head: bool = false;    // the iterator's head bit
var vcb_dl: i32 = -1;          // StoredDL (!dbg md id)
var vcb_cf: bool = false;      // ConstantFolder (a local IRBuilder<>) instead of InstSimplifyFolder

// SetInsertPoint(I)
fn vcb_set(i: i32) { vcb_bb = inst_parent(i); vcb_pos = i; vcb_head = false; vcb_dl = inst_get_md(i, 0); }
// SetInsertPoint(It) for an iterator (instruction, head bit); It must be dereferenceable
fn vcb_set_it(pos: i32, head: bool) { vcb_bb = inst_parent(pos); vcb_pos = pos; vcb_head = head; vcb_dl = inst_get_md(pos, 0); }
// IRBuilder<> Builder(I)
fn vcb_local(i: i32) { vcb_set(i); vcb_cf = true; }

// IRBuilderBase::Insert(I, Name)
fn vcb_insert(iv: i32, name: const u8[:]) -> i32 {
    inst_insert_at(iv, vcb_bb, vcb_pos, vcb_head);
    if vals[iv].ty != T_VOID && name.len > 0 { set_name(iv, name); }
    if vcb_dl >= 0 { inst_set_md(iv, 0, vcb_dl); }
    return iv;
}

// InstSimplifyFolder: SimplifyQuery(DL)
var vcf_save_dt: bool = false;
var vcf_save_ac: bool = false;
var vcf_save_tli: bool = false;
var vcf_save_dc: bool = false;
fn vcf_begin() -> SQ {
    vcf_save_dt = sq_no_dt; vcf_save_ac = sq_no_ac; vcf_save_tli = sq_no_tli; vcf_save_dc = dc_active;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true; dc_active = false;
    return sq_new(-1);
}
fn vcf_end() { sq_no_dt = vcf_save_dt; sq_no_ac = vcf_save_ac; sq_no_tli = vcf_save_tli; dc_active = vcf_save_dc; }

// Folder.FoldBinOp / FoldBinOpFMF
fn vcf_binop(o: i64, a: i32, b: i32, fmf: u8) -> i32 {
    if vcb_cf {
        if !is_constant(a) || !is_constant(b) { return -1; }
        if is_desirable_binop(o) { return ce_binop(o, a, b, 0); }
        return cf_binop(o, a, b);
    }
    let q = vcf_begin();
    let r = if is_fp_or_fp_vec(vals[a].ty) { simplify_binop_fmf(o, a, b, fmf, q, RECURSION_LIMIT) } else { simplify_binop(o, a, b, q, RECURSION_LIMIT) };
    vcf_end();
    return r;
}
// CreateBinOp(Opc, LHS, RHS, Name) / CreateInsertNUWNSWBinOp / CreateOr(.., IsDisjoint): fl = the flags
fn vcb_binop(o: i64, a: i32, b: i32, name: const u8[:], fl: u8) -> i32 {
    let f = vcf_binop(o, a, b, 0);
    if f >= 0 { return f; }
    let i = create_inst(o, vals[a].ty, [a, b]);
    insts[inst_of(i)].flags = fl;
    return vcb_insert(i, name);
}
// CreateFNegFMF(V, FMFSource) / CreateUnOp(FNeg, V)
fn vcb_fneg(v: i32, fmf: u8, name: const u8[:]) -> i32 {
    if vcb_cf {
        if is_constant(v) { let r = cf_fold_unary(OP_FNEG, v); if r >= 0 { return r; } }
    } else {
        let q = vcf_begin();
        let r = simplify_fneg(v, fmf, q);
        vcf_end();
        if r >= 0 { return r; }
    }
    let i = create_inst(OP_FNEG, vals[v].ty, [v]);
    insts[inst_of(i)].fmf = fmf;
    return vcb_insert(i, name);
}
// CreateNAryOp(Opc, Ops)
fn vcb_nary(o: i64, opsv: const i32[:], name: const u8[:]) -> i32 {
    if is_binary_op(o) { return vcb_binop(o, opsv[0], opsv[1], name, 0); }
    if o == OP_FNEG { return vcb_fneg(opsv[0], 0, name); }
    fatal("VectorCombine: CreateNAryOp: unexpected opcode");
    return -1;
}
// CreateCmp(Pred, LHS, RHS, Name)
fn vcb_cmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if vcb_cf {
        if is_constant(a) && is_constant(b) { let r = cf_compare(p, a, b); if r >= 0 { return r; } }
    } else {
        let q = vcf_begin();
        let r = simplify_cmp(p, a, b, q, RECURSION_LIMIT);
        vcf_end();
        if r >= 0 { return r; }
    }
    let o = if p < 32 { OP_FCMP } else { OP_ICMP };
    let i = create_inst(o, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(i)].pred = p as u8;
    return vcb_insert(i, name);
}
// CreateSelectFMF(C, True, False, FMFSource, Name) (no MDFrom)
fn vcb_select(c: i32, t: i32, f: i32, fmf: u8, name: const u8[:]) -> i32 {
    if vcb_cf {
        if is_constant(c) && is_constant(t) && is_constant(f) { let r = cf_select(c, t, f); if r >= 0 { return r; } }
    } else {
        let q = vcf_begin();
        let r = simplify_select(c, t, f, fmf, q, RECURSION_LIMIT);
        vcf_end();
        if r >= 0 { return r; }
    }
    let i = create_inst(OP_SELECT, vals[t].ty, [c, t, f]);
    if is_fp_math_operator(i) { insts[inst_of(i)].fmf = fmf; }
    return vcb_insert(i, name);
}
// CreateCast(Op, V, DestTy, Name) (also CreateBitCast, CreateZExt, CreateTrunc without flags)
fn vcb_cast(o: i64, v: i32, ty: i32, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    if vcb_cf {
        if is_constant(v) { let r = ce_cast(o, v, ty); if r >= 0 { return r; } }
    } else {
        let q = vcf_begin();
        let r = simplify_cast(o, v, ty, q, RECURSION_LIMIT);
        vcf_end();
        if r >= 0 { return r; }
    }
    return vcb_insert(create_inst(o, ty, [v]), name);
}
// CreatePointerBitCastOrAddrSpaceCast(V, DestTy)
fn vcb_ptr_bitcast_or_ascast(v: i32, ty: i32) -> i32 {
    if vals[v].ty == ty { return v; }
    if ty_kind(vals[v].ty) == TK_PTR && ty_kind(ty) == TK_PTR && ptr_as(vals[v].ty) != ptr_as(ty) { return vcb_cast(OP_ADDRSPACECAST, v, ty, ""); }
    return vcb_cast(OP_BITCAST, v, ty, "");
}
// CreateFreeze(V, Name): no folding
fn vcb_freeze(v: i32, name: const u8[:]) -> i32 { vcb_insert(create_inst(OP_FREEZE, vals[v].ty, [v]), name) }

// CreateShuffleVector(V1, V2, Mask, Name)
fn vcb_shuffle(v1: i32, v2: i32, mask: const i32[:], name: const u8[:]) -> i32 {
    let t1 = vals[v1].ty;
    let rt = ty_vector(ty_elem(t1), mask.len, ty_kind(t1) == TK_SVEC);
    if vcb_cf {
        if is_constant(v1) && is_constant(v2) {
            var tmp: i32[>..<] = [];
            for m in mask { tmp.push(m); }
            let r = ce_shufflevector(v1, v2, tmp);
            if r >= 0 { return r; }
        }
    } else {
        let mark = is_ops.len;
        for m in mask { is_ops.push(m); }
        let q = vcf_begin();
        let r = simplify_shufflevector_mask(rt, v1, v2, mark, mask.len, q, RECURSION_LIMIT);
        vcf_end();
        if r >= 0 { return r; }
    }
    let s = create_inst(OP_SHUFFLEVECTOR, rt, [v1, v2]);
    let at = ints.len as i32;
    for m in mask { ints.push(m); }
    insts[inst_of(s)].aux = at;
    insts[inst_of(s)].naux = mask.len as i32;
    return vcb_insert(s, name);
}
fn vcb_shuffle1(v: i32, mask: const i32[:], name: const u8[:]) -> i32 { vcb_shuffle(v, c_poison(vals[v].ty), mask, name) }

// CreateExtractElement(Vec, Idx, Name)
fn vcb_extract(vec: i32, idx: i32, name: const u8[:]) -> i32 {
    if vcb_cf {
        if is_constant(vec) && is_constant(idx) { return ce_extractelement(vec, idx); }
    } else {
        let q = vcf_begin();
        let r = simplify_extractelement(vec, idx, q);
        vcf_end();
        if r >= 0 { return r; }
    }
    return vcb_insert(create_inst(OP_EXTRACTELEMENT, ty_elem(vals[vec].ty), [vec, idx]), name);
}
// CreateInsertElement(Vec, NewElt, Idx, Name)
fn vcb_insert_elt(vec: i32, elt: i32, idx: i32, name: const u8[:]) -> i32 {
    if vcb_cf {
        if is_constant(vec) && is_constant(elt) && is_constant(idx) { return ce_insertelement(vec, elt, idx); }
    } else {
        let q = vcf_begin();
        let r = simplify_insertelement(vec, elt, idx, q);
        vcf_end();
        if r >= 0 { return r; }
    }
    return vcb_insert(create_inst(OP_INSERTELEMENT, vals[vec].ty, [vec, elt, idx]), name);
}
fn vcb_int64(k: i64) -> i32 { c_int(T_I64, k) }

// CreateVectorSplat(EC, V, Name)
fn vcb_vector_splat(n: i64, scalable: bool, v: i32, name: const u8[:]) -> i32 {
    let p = c_poison(ty_vector(vals[v].ty, n, scalable));
    var nm: u8[>..] = [];
    nm.append(name);
    nm.append(".splatinsert");
    let ins = vcb_insert_elt(p, v, vcb_int64(0), nm);
    var zeros: i32[>..<] = [];
    for k in n { zeros.push(0); }
    var nm2: u8[>..] = [];
    nm2.append(name);
    nm2.append(".splat");
    return vcb_shuffle1(ins, zeros, nm2);
}

fn vcb_align_code(al: i64) -> u8 { if al <= 0 { 0 } else { (log2_exact(al) + 1) as u8 } }
fn vc_align_of(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { (1 as i64) << ((a - 1) as i64) }; }
fn vc_set_align(i: i32, al: i64) { insts[inst_of(i)].align = vcb_align_code(al); }
// CreateAlignedLoad(Ty, Ptr, Align, Name)
fn vcb_load(ty: i32, p: i32, al: i64, name: const u8[:]) -> i32 {
    let li = create_inst(OP_LOAD, ty, [p]);
    vc_set_align(li, al);
    return vcb_insert(li, name);
}
// CreateStore(Val, Ptr): the ABI alignment of Val's type
fn vcb_store(v: i32, p: i32) -> i32 {
    let si = create_inst(OP_STORE, T_VOID, [v, p]);
    vc_set_align(si, dl_align(vals[v].ty, true));
    return vcb_insert(si, "");
}
// CreateInBoundsGEP(Ty, Ptr, IdxList, Name): scalar indices on a scalar pointer
fn vcb_inbounds_gep(ty: i32, p: i32, idxs: const i32[:], name: const u8[:]) -> i32 {
    if !vcb_cf {
        let mark = is_ops.len;
        is_ops.push(p);
        for x in idxs { is_ops.push(x); }
        let q = vcf_begin();
        let r = simplify_gep(ty, p, mark + 1, idxs.len, GEP_INBOUNDS | GEP_NUSW, q, RECURSION_LIMIT);
        vcf_end();
        is_ops.resize(mark);
        if r >= 0 { return r; }
    } else {
        vc_not_ported("CreateInBoundsGEP with a ConstantFolder");
    }
    var opsv: i32[>..<] = [];
    opsv.push(p);
    for x in idxs { opsv.push(x); }
    let g = create_inst(OP_GEP, vals[p].ty, opsv);
    insts[inst_of(g)].ty2 = ty;
    insts[inst_of(g)].flags = GEP_INBOUNDS | GEP_NUSW;
    return vcb_insert(g, name);
}
// CreatePHI(Ty, NumReservedValues, Name)
fn vcb_phi(ty: i32, name: const u8[:]) -> i32 { vcb_insert(create_inst(OP_PHI, ty, []), name) }
// CreateExtractValue(Agg, {Idx}, Name) with a ConstantFolder (only constants fold)
fn vcb_extract_value(agg: i32, idx: i64, name: const u8[:]) -> i32 {
    if is_constant(agg) { vc_not_ported("CreateExtractValue of a constant"); }
    let rt = ty_index(vals[agg].ty, idx);
    let e = create_inst(OP_EXTRACTVALUE, rt, [agg]);
    let at = ints.len as i32;
    ints.push(idx as i32);
    insts[inst_of(e)].aux = at;
    insts[inst_of(e)].naux = 1;
    return vcb_insert(e, name);
}

// Folder.FoldIntrinsic(ID, Ops, RetTy, FMF, CtxF): ConstantFolder does not fold intrinsics
fn vcf_intrinsic(id: i64, argsv: const i32[:], rty: i32, fmf: u8) -> i32 {
    if vcb_cf { return -1; }
    let mark = is_ops.len;
    for a in argsv { is_ops.push(a); }
    let q = vcf_begin();
    let r = simplify_intrinsic_args(id as i32, rty, mark, argsv.len, fmf, q, vc_fv, EB_IGNORE, RM_NEAREST);
    vcf_end();
    is_ops.resize(mark);
    return r;
}
// createCallHelper(Fn, Args, Name, FMFSource)
fn vcb_call(f: i32, argsv: const i32[:], fmf: u8, name: const u8[:]) -> i32 {
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let c = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(c)].ty2 = fty;
    if is_fp_math_operator(c) { insts[inst_of(c)].fmf = fmf; }
    return vcb_insert(c, name);
}
// CreateIntrinsic(ID, OverloadTypes, Args, FMFSource, Name)
fn vcb_intrinsic(id: i64, ov: const i32[:], argsv: const i32[:], fmf: u8, name: const u8[:]) -> i32 {
    let rty = ty_fn_ret(intr_get_type(id, ov));
    let r = vcf_intrinsic(id, argsv, rty, fmf);
    if r >= 0 { return r; }
    return vcb_call(au_get_declaration(id, ov), argsv, fmf, name);
}
// Intrinsic::getOrInsertDeclaration(M, ID, RetTy, ArgTys)
fn vc_decl_for_signature(id: i64, rty: i32, argsv: const i32[:]) -> i32 {
    let at = ints.len as i32;
    ints.push(rty);
    for a in argsv { ints.push(vals[a].ty); }
    let fty = ty_func_run(at, argsv.len + 1, false);
    if !intr_signature_valid(id, fty) { fatal("internal: VectorCombine: intrinsic signature does not match"); }
    var tys: i32[>..<] = [];
    for t in otys { tys.push(t); }
    return au_get_declaration(id, tys);
}
// CreateIntrinsic(RetTy, ID, Args, FMFSource, Name)
fn vcb_intrinsic_rt(rty: i32, id: i64, argsv: const i32[:], fmf: u8, name: const u8[:]) -> i32 {
    let r = vcf_intrinsic(id, argsv, rty, fmf);
    if r >= 0 { return r; }
    return vcb_call(vc_decl_for_signature(id, rty, argsv), argsv, fmf, name);
}
// CreateUnaryIntrinsic(ID, V, FMFSource, Name): the declaration first, then the folder
fn vcb_unary_intrinsic(id: i64, v: i32, fmf: u8, name: const u8[:]) -> i32 {
    let f = au_get_declaration(id, [vals[v].ty as i32]);
    let rty = ty_fn_ret(globs[glob_of(f)].vty);
    let r = vcf_intrinsic(id, [v], rty, fmf);
    if r >= 0 { return r; }
    return vcb_call(f, [v], fmf, name);
}

// ---------------------------------------------------------------- small helpers

// m_ConstantInt(uint64_t &): a ConstantInt whose value fits in 64 bits
fn vc_cint_u64(c: i32) -> bool, u64 {
    if c < 0 || vals[c].kind != VK_CINT { return false, 0; }
    let a = ci_ap(c);
    if ap_active_bits(a) > 64 { return false, 0; }
    return true, ap_zext64(a);
}
// m_ExtractElt(m_Value(V), m_ConstantInt(C))
fn vc_m_ext_c(v: i32) -> bool, i32, u64 {
    if !is_inst_op(v, OP_EXTRACTELEMENT) { return false, -1, 0; }
    let ok, c = vc_cint_u64(op(v, 1));
    if !ok { return false, -1, 0; }
    return true, op(v, 0), c;
}
// m_InsertElt(m_Value(V), m_Value(E), m_ConstantInt(C))
fn vc_m_ins_c(v: i32) -> bool, i32, i32, u64 {
    if !is_inst_op(v, OP_INSERTELEMENT) { return false, -1, -1, 0; }
    let ok, c = vc_cint_u64(op(v, 2));
    if !ok { return false, -1, -1, 0; }
    return true, op(v, 0), op(v, 1), c;
}
fn vc_is_shuffle(v: i32) -> bool { is_inst_op(v, OP_SHUFFLEVECTOR) }
fn vc_mask_len(sv: i32) -> i64 { insts[inst_of(sv)].naux as i64 }
fn vc_mask_at(sv: i32, k: i64) -> i32 { ints[insts[inst_of(sv)].aux + k as i32] }
fn vc_mask(sv: i32, out: i32[>..<]&) { out.clear(); for k in vc_mask_len(sv) { out.push(vc_mask_at(sv, k)); } }
fn vc_is_binop(v: i32) -> bool { is_inst(v) && is_binary_op(iop(v)) }
fn vc_is_cmp(v: i32) -> bool { is_inst(v) && (iop(v) == OP_ICMP || iop(v) == OP_FCMP) }
fn vc_is_cast(v: i32) -> bool { is_inst(v) && is_cast_op(iop(v)) }
fn vc_has_one_use(v: i32) -> bool { let u = vals[v].first_use; u >= 0 && uses[u].next < 0 }
fn vc_num_uses(v: i32) -> i64 { var c: i64 = 0; var u = vals[v].first_use; while u >= 0 { c++; u = uses[u].next; } return c; }
fn vc_has_one_user(v: i32) -> bool {
    let u = vals[v].first_use;
    if u < 0 { return false; }
    let us = uses[u].user;
    var n = uses[u].next;
    while n >= 0 { if uses[n].user != us { return false; } n = uses[n].next; }
    return true;
}
fn vc_user_back(v: i32) -> i32 { uses[vals[v].first_use].user }
fn vc_is_fixed_vec(t: i32) -> bool { ty_kind(t) == TK_FVEC }
fn vc_is_int_div_rem(o: i64) -> bool { o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM }
fn vc_is_idempotent(o: i64) -> bool { o == OP_AND || o == OP_OR }
fn vc_cmp_is_commutative(c: i32) -> bool {
    let p = inst_pred(c);
    if iop(c) == OP_ICMP { return p == VC_EQ || p == VC_NE; }
    // FCmpInst::isCommutative: oeq, one, ueq, une, ord, uno, false, true
    return p == 1 || p == 6 || p == 9 || p == 14 || p == 7 || p == 8 || p == 0 || p == 15;
}
// peekThroughBitcasts
fn vc_peek_bitcasts(v0: i32) -> i32 { var v = v0; while is_inst_op(v, OP_BITCAST) { v = op(v, 0); } return v; }
// a ConstantInt of an integer type (ConstantInt::get(Ty, V))
fn vc_cint(ty: i32, x: u64) -> i32 { c_int_ty(ty, x) }
// Function::hasOptSize
fn vc_has_opt_size(fv: i32) -> bool { func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize) }
// InstructionCost addition helpers (invalid states propagate)
fn vc_add(a: i64, b: i64) -> i64 { tc_add(a, b) }

// ---------------------------------------------------------------- loads

// canWidenLoad(Load, TTI)
fn vc_can_widen_load(ld: i32) -> bool {
    if ld < 0 || !is_inst_op(ld, OP_LOAD) || !ld_is_simple(ld) || !vc_has_one_use(ld) ||
       func_has_fn_attr(inst_func(ld), AK_SanitizeMemTag) || must_suppress_speculation(ld) { return false; }
    let sty = ty_scalar(vals[ld].ty);
    let ss = tt_prim_bits(sty);
    let mvs = tv_min_vector_register_bit_width();
    if ss == 0 || mvs == 0 || mvs % ss != 0 || ss % 8 != 0 { return false; }
    return true;
}

// isSafeToLoadUnconditionally(V, Ty, Align(1), DL, ScanFrom, AC, DT)
fn vc_safe_to_load(v: i32, ty: i32, scan_from: i32) -> bool {
    return ld_safe_to_load_unconditionally_ty_acdt(v, ty, 1, scan_from);
}

// vectorizeLoadInsert
fn vc_vectorize_load_insert(i: i32) -> bool {
    // m_InsertElt(m_Poison(), m_OneUse(m_Value(Scalar)), m_ZeroInt())
    if !is_inst_op(i, OP_INSERTELEMENT) || !is_poison(op(i, 0)) || !m_zero_int(op(i, 2)) { return false; }
    let scalar = op(i, 1);
    if !vc_has_one_use(scalar) || is_constant_data(scalar) { return false; }
    var x = scalar;
    let has_extract = is_inst_op(scalar, OP_EXTRACTELEMENT) && m_zero_int(op(scalar, 1));
    if has_extract { x = op(scalar, 0); }
    let ld = if is_inst_op(x, OP_LOAD) { x } else { -1 };
    if !vc_can_widen_load(ld) { return false; }
    let sty = vals[scalar].ty as i32;
    let ss = tt_prim_bits(sty);
    let mvs = tv_min_vector_register_bit_width();
    var src = strip_ptr_casts(op(ld, 0));
    let minelts = mvs / ss;
    let minvt = ty_vector(sty, minelts, false);
    var off_elt: i64 = 0;
    var al = vc_align_of(ld);
    if !vc_safe_to_load(src, minvt, ld) {
        src = strip_and_accumulate_offsets(src, false, false, false);
        let off = vt_off;
        if off < 0 { return false; }
        let sbytes_ = ss / 8;
        if off % sbytes_ != 0 { return false; }
        off_elt = off / sbytes_;
        if off_elt >= minelts { return false; }
        if !vc_safe_to_load(src, minvt, ld) { return false; }
        al = tt_common_align(al, off);
    }
    let pa = pointer_alignment(src);
    if pa > al { al = pa; }
    let lty = vals[ld].ty as i32;
    let as_ = ptr_as(vals[op(ld, 0)].ty);
    var old = tv_mem(OP_LOAD, lty, al, as_, vc_kind);
    var dem: bool[>..<] = [];
    for k in minelts { dem.push(k == 0); }
    old = vc_add(old, tv_scalarization_overhead(minvt, dem, true, has_extract, vc_kind));
    var nc = tv_mem(OP_LOAD, minvt, al, as_, vc_kind);
    let ty = vals[i].ty as i32;
    let outn = ty_count(ty);
    var mask: i32[>..<] = [];
    for k in outn { mask.push(-1); }
    mask[0] = off_elt as i32;
    if off_elt != 0 { nc = vc_add(nc, tv_shuffle_simple(SK_PERMUTESINGLESRC, ty, minvt, mask, vc_kind)); }
    if old < nc || !tc_valid(nc) { return false; }
    vcb_local(ld);
    let cp = vcb_ptr_bitcast_or_ascast(src, ty_ptr(as_));
    var vl = vcb_load(minvt, cp, al, "");
    vl = vcb_shuffle1(vl, mask, "");
    vc_replace(i, vl, true);
    return true;
}

// widenSubvectorLoad
fn vc_widen_subvector_load(i: i32) -> bool {
    // ShuffleVectorInst::isIdentityWithPadding
    let n0 = ty_count(vals[op(i, 0)].ty);
    let nm = vc_mask_len(i);
    if ty_kind(vals[op(i, 0)].ty) == TK_SVEC || nm <= n0 { return false; }
    var mask: i32[>..<] = [];
    vc_mask(i, mask);
    if !vc_mask_identity_with_padding(mask, n0) { return false; }
    var opidx: i64 = 0;
    for m in mask { if m as i64 >= n0 { opidx = 1; } }
    let ld = if is_inst_op(op(i, opidx), OP_LOAD) { op(i, opidx) } else { -1 };
    if !vc_can_widen_load(ld) { return false; }
    let ty = vals[i].ty as i32;
    let src = strip_ptr_casts(op(ld, 0));
    var al = vc_align_of(ld);
    if !vc_safe_to_load(src, ty, ld) { return false; }
    let pa = pointer_alignment(src);
    if pa > al { al = pa; }
    let lty = vals[ld].ty as i32;
    let as_ = ptr_as(vals[op(ld, 0)].ty);
    let old = tv_mem(OP_LOAD, lty, al, as_, vc_kind);
    let nc = tv_mem(OP_LOAD, ty, al, as_, vc_kind);
    if old < nc || !tc_valid(nc) { return false; }
    vcb_local(ld);
    let cp = vcb_ptr_bitcast_or_ascast(src, ty_ptr(as_));
    let vl = vcb_load(ty, cp, al, "");
    vc_replace(i, vl, true);
    return true;
}

// ShuffleVectorInst::isIdentityWithPadding for a mask with more elements than the source (n0)
fn vc_mask_identity_with_padding(mask: const i32[:], n0: i64) -> bool {
    for k in mask.len {
        if k >= n0 { if mask[k] != -1 { return false; } continue; }
    }
    // isIdentityMaskImpl(Mask.take_front(NumOpElts), NumOpElts)
    var uses_l = false;
    var uses_r = false;
    for k in n0 {
        let m = mask[k] as i64;
        if m == -1 { continue; }
        if m != k && m != n0 + k { return false; }
        if m == k { uses_l = true; } else { uses_r = true; }
        if uses_l && uses_r { return false; }
    }
    return uses_l || uses_r;
}

// ---------------------------------------------------------------- extract-extract

// getShuffleExtract(Ext0, Ext1, PreferredExtractIndex); pref -1 = InvalidIndex
fn vc_get_shuffle_extract(e0: i32, e1: i32, pref: i64) -> i32 {
    let ok0, i0 = vc_cint_u64(op(e0, 1));
    let ok1, i1 = vc_cint_u64(op(e1, 1));
    let x0 = (i0 & 0xFFFFFFFF) as i64;
    let x1 = (i1 & 0xFFFFFFFF) as i64;
    if x0 == x1 { return -1; }
    let vt = vals[op(e0, 0)].ty as i32;
    let c0 = tv_vec_inst_i(e0, vt, x0, vc_kind);
    let c1 = tv_vec_inst_i(e1, vt, x1, vc_kind);
    if !tc_valid(c0) && !tc_valid(c1) { return -1; }
    if c0 > c1 { return e0; }
    if c1 > c0 { return e1; }
    if pref == x0 { return e1; }
    if pref == x1 { return e0; }
    return if x0 > x1 { e0 } else { e1 };
}

// isExtractExtractCheap: (cheap, ConvertToShuffle)
fn vc_is_extract_extract_cheap(e0: i32, e1: i32, i: i32, pref: i64) -> bool, i32 {
    let o = iop(i);
    let s0 = op(e0, 0);
    let s1 = op(e1, 0);
    let sty = vals[e0].ty as i32;
    let vt = vals[s0].ty as i32;
    var sc: i64 = 0;
    var vc: i64 = 0;
    let isbin = is_binary_op(o);
    if isbin {
        sc = tv_arith0(o, sty, vc_kind);
        vc = tv_arith0(o, vt, vc_kind);
    } else {
        let p = inst_pred(i);
        sc = tv_cmpsel(o, sty, cmp_result_ty(sty), p, vc_kind, 0, 0);
        vc = tv_cmpsel(o, vt, cmp_result_ty(vt), p, vc_kind, 0, 0);
    }
    let ok0, i0 = vc_cint_u64(op(e0, 1));
    let ok1, i1 = vc_cint_u64(op(e1, 1));
    let x0 = (i0 & 0xFFFFFFFF) as i64;
    let x1 = (i1 & 0xFFFFFFFF) as i64;
    let c0 = tv_vec_inst_i(e0, vt, x0, vc_kind);
    let c1 = tv_vec_inst_i(e1, vt, x1, vc_kind);
    let best_ext = if c0 > c1 { x0 } else { x1 };
    let best_ins = if c0 > c1 { x1 } else { x0 };
    let cheap = if c0 < c1 { c0 } else { c1 };
    var oldc: i64 = 0;
    var newc: i64 = 0;
    if s0 == s1 && x0 == x1 {
        let tax = if e0 == e1 { vc_num_uses(e0) != 2 } else { !vc_has_one_use(e0) || !vc_has_one_use(e1) };
        oldc = vc_add(cheap, sc);
        newc = vc_add(vc_add(vc, cheap), if tax { cheap } else { 0 });
    } else {
        oldc = vc_add(vc_add(c0, c1), sc);
        newc = vc_add(vc_add(vc, cheap), vc_add(if !vc_has_one_use(e0) { c0 } else { 0 }, if !vc_has_one_use(e1) { c1 } else { 0 }));
    }
    let conv = vc_get_shuffle_extract(e0, e1, pref);
    if conv >= 0 {
        if isbin && flag_bool("disable-binop-extract-shuffle", false) { return true, conv; }
        if vc_is_fixed_vec(vt) {
            var mask: i32[>..<] = [];
            for k in ty_count(vt) { mask.push(-1); }
            mask[best_ins] = best_ext as i32;
            newc = vc_add(newc, tv_shuffle(SK_PERMUTESINGLESRC, vt, vt, mask, vc_kind, 0, -1, conv, -1, 1, -1));
        } else {
            newc = vc_add(newc, tv_shuffle(SK_PERMUTESINGLESRC, vt, vt, [], vc_kind, 0, -1, conv, -1, 1, -1));
        }
    }
    return oldc < newc, conv;
}

// createShiftShuffle(Vec, OldIndex, NewIndex, Builder)
fn vc_create_shift_shuffle(vec: i32, oldi: i64, newi: i64) -> i32 {
    var mask: i32[>..<] = [];
    for k in ty_count(vals[vec].ty) { mask.push(-1); }
    mask[newi] = oldi as i32;
    return vcb_shuffle1(vec, mask, "shift");
}

// translateExtract(ExtElt, NewIndex, Builder)
fn vc_translate_extract(e: i32, newi: i64) -> i32 {
    let x = op(e, 0);
    if !vc_is_fixed_vec(vals[x].ty) { return -1; }
    if is_constant(x) { return -1; }
    let ok, c = vc_cint_u64(op(e, 1));
    return vc_create_shift_shuffle(x, c as i64, newi);
}

// foldExtractExtract
fn vc_fold_extract_extract(i: i32) -> bool {
    if !spec_safe(i, -1, false) { return false; }
    let is_cmp = vc_is_cmp(i);
    if !is_cmp && !vc_is_binop(i) { return false; }
    let i0 = op(i, 0);
    let i1 = op(i, 1);
    if !is_inst(i0) || !is_inst(i1) { return false; }
    let ok0, v0, c0 = vc_m_ext_c(i0);
    if !ok0 { return false; }
    let ok1, v1, c1 = vc_m_ext_c(i1);
    if !ok1 || vals[v0].ty != vals[v1].ty { return false; }
    if vc_is_fixed_vec(vals[v0].ty) {
        let n = ty_count(vals[v0].ty) as u64;
        if c0 >= n || c1 >= n { return false; }
    }
    var ins_idx: i64 = -1;
    if vc_has_one_use(i) {
        let u = vc_user_back(i);
        let ok, a, b, c = vc_m_ins_c(u);
        if ok { ins_idx = c as i64; }
    }
    let cheap, conv = vc_is_extract_extract_cheap(i0, i1, i, ins_idx);
    if cheap { return false; }
    var x0 = op(i0, 0);
    var x1 = op(i1, 0);
    if conv >= 0 {
        let cheap_idx = if conv == i0 { c1 } else { c0 };
        let ne = vc_translate_extract(conv, cheap_idx as i64);
        if ne < 0 { return false; }
        if conv == i0 { x0 = ne; } else { x1 = ne; }
    }
    let idx = if conv == i0 { op(i1, 1) } else { op(i0, 1) };
    var nw: i32 = -1;
    if is_cmp {
        let vcmp = vcb_cmp(inst_pred(i), x0, x1, "");
        nw = vcb_extract(vcmp, idx, "foldExtExtCmp");
    } else {
        let vbo = vcb_binop(iop(i), x0, x1, "foldExtExtBinop", 0);
        if is_inst(vbo) { vu_copy_ir_flags(vbo, i, true); }
        nw = vcb_extract(vbo, idx, "foldExtExtBinop");
    }
    vcw_push(i0);
    vcw_push(i1);
    vc_replace(i, nw, true);
    return true;
}

// ---------------------------------------------------------------- insert / extract folds

// foldInsExtFNeg
fn vc_fold_ins_ext_fneg(i: i32) -> bool {
    let ok, dst, fneg, insidx = vc_m_ins_c(i);
    if !ok || !is_inst(fneg) || !vc_has_one_use(fneg) { return false; }
    // m_FNeg: fneg X, or fsub -0.0, X
    let e = m_fneg(fneg);
    if e < 0 || !is_inst(e) { return false; }
    let oke, src, extidx = vc_m_ext_c(e);
    if !oke { return false; }
    let dvt = vals[dst].ty as i32;
    let dst_sty = ty_scalar(dvt);
    let svt = vals[src].ty as i32;
    if !vc_is_fixed_vec(svt) || dst_sty != ty_scalar(svt) { return false; }
    let nd = ty_count(dvt);
    let ns = ty_count(svt);
    if extidx > ns as u64 || insidx >= nd as u64 || nd == 1 { return false; }
    let ext = extidx as i64;
    let ins = insidx as i64;
    var mask: i32[>..<] = [];
    for k in nd { mask.push(k as i32); }
    mask[ins] = ((ext % nd) + nd) as i32;
    var old = vc_add(tv_arith0(OP_FNEG, dst_sty, vc_kind), tv_vec_inst_i(i, dvt, ins, vc_kind));
    if vc_has_one_use(e) { old = vc_add(old, tv_vec_inst_i(e, svt, ext, vc_kind)); }
    var nc = vc_add(tv_arith0(OP_FNEG, svt, vc_kind), tv_shuffle_simple(SK_PERMUTETWOSRC, dvt, dvt, mask, vc_kind));
    let lenchg = ns != nd;
    var smask: i32[>..<] = [];
    if lenchg {
        for k in nd { smask.push(-1); }
        smask[ext % nd] = ext as i32;
        nc = vc_add(nc, tv_shuffle_simple(SK_PERMUTESINGLESRC, dvt, svt, smask, vc_kind));
    }
    if nc > old { return false; }
    let vfneg = vcb_fneg(src, inst_fmf(fneg), "");
    var ns_: i32 = -1;
    if lenchg {
        let lc = vcb_shuffle1(vfneg, smask, "");
        ns_ = vcb_shuffle(dst, lc, mask, "");
        vcw_push_value(lc);
    } else {
        ns_ = vcb_shuffle(dst, vfneg, mask, "");
    }
    vcw_push_value(vfneg);
    vc_replace(i, ns_, true);
    return true;
}

// foldInsExtBinop
fn vc_fold_ins_ext_binop(i: i32) -> bool {
    let ok, vb, sb, index = vc_m_ins_c(i);
    if !ok { return false; }
    if !vc_is_binop(vb) || !vc_has_one_use(vb) || !vc_is_binop(sb) || !vc_has_one_use(sb) { return false; }
    let o = iop(vb);
    if o != iop(sb) { return false; }
    let rt = vals[i].ty as i32;
    if !vc_is_fixed_vec(rt) { return false; }
    let old = vc_add(vc_add(tv_inst_cost(i, vc_kind), tv_inst_cost(vb, vc_kind)), tv_inst_cost(sb, vc_kind));
    let ix = (index & 0xFFFFFFFF) as i64;
    let nc = vc_add(vc_add(tv_arith0(o, rt, vc_kind), tv_vec_inst(OP_INSERTELEMENT, rt, ix, op(vb, 0), op(sb, 0), vc_kind)),
                    tv_vec_inst(OP_INSERTELEMENT, rt, ix, op(vb, 1), op(sb, 1), vc_kind));
    if nc > old { return false; }
    let n0 = vcb_insert_elt(op(vb, 0), op(sb, 0), vcb_int64(index as i64), "");
    let n1 = vcb_insert_elt(op(vb, 1), op(sb, 1), vcb_int64(index as i64), "");
    let nb = vcb_binop(o, n0, n1, "", 0);
    if is_inst(nb) {
        vu_copy_ir_flags(nb, vb, true);
        vu_and_ir_flags(nb, sb);
    }
    vcw_push_value(n0);
    vcw_push_value(n1);
    vc_replace(i, nb, true);
    return true;
}

// foldBitOpOfCastops
fn vc_fold_bitop_of_castops(i: i32) -> bool {
    if !vc_is_binop(i) { return false; }
    let o = iop(i);
    if o != OP_AND && o != OP_OR && o != OP_XOR { return false; }
    let lc = op(i, 0);
    let rc = op(i, 1);
    if !vc_is_cast(lc) || !vc_is_cast(rc) { return false; }
    let co = iop(lc);
    if co != iop(rc) { return false; }
    if co != OP_BITCAST && co != OP_TRUNC && co != OP_SEXT && co != OP_ZEXT { return false; }
    let ls = op(lc, 0);
    let rs = op(rc, 0);
    if vals[ls].ty != vals[rs].ty { return false; }
    let sty = vals[ls].ty as i32;
    let dty = vals[i].ty as i32;
    if co != OP_BITCAST && (!vc_is_fixed_vec(sty) || !vc_is_fixed_vec(dty)) { return false; }
    if !ty_is_int(ty_scalar(sty)) || !ty_is_int(ty_scalar(dty)) { return false; }
    let lcc = tv_cast(co, dty, sty, 0, vc_kind, lc);
    let rcc = tv_cast(co, dty, sty, 0, vc_kind, rc);
    let old = vc_add(vc_add(tv_arith0(o, dty, vc_kind), lcc), rcc);
    let gc = tv_cast(co, dty, sty, 0, vc_kind, -1);
    var nc = vc_add(tv_arith0(o, sty, vc_kind), gc);
    if !vc_has_one_use(lc) { nc = vc_add(nc, lcc); }
    if !vc_has_one_use(rc) { nc = vc_add(nc, rcc); }
    if nc > old { return false; }
    var nm: u8[>..] = [];
    nm.append(val_name(i));
    nm.append(".inner");
    let nop = vcb_binop(o, ls, rs, nm, 0);
    if vc_is_binop(nop) { vu_copy_ir_flags(nop, i, true); }
    vcw_push_value(nop);
    let ncast = create_inst(co, vals[i].ty, [nop]);
    vu_copy_ir_flags(ncast, lc, true);
    vu_and_ir_flags(ncast, rc);
    let r = vcb_insert(ncast, "");
    vc_replace(i, r, true);
    return true;
}

// foldBitOpOfCastConstant
fn vc_fold_bitop_of_cast_constant(i: i32) -> bool {
    // m_c_BitwiseLogic(m_Instruction(LHS), m_Constant(C))
    if !vc_is_binop(i) { return false; }
    let o = iop(i);
    if o != OP_AND && o != OP_OR && o != OP_XOR { return false; }
    var lhs: i32 = -1;
    var c: i32 = -1;
    if is_inst(op(i, 0)) && is_constant(op(i, 1)) { lhs = op(i, 0); c = op(i, 1); }
    else if is_inst(op(i, 1)) && is_constant(op(i, 0)) { lhs = op(i, 1); c = op(i, 0); }
    else { return false; }
    if !vc_is_cast(lhs) { return false; }
    let co = iop(lhs);
    if co != OP_BITCAST && co != OP_ZEXT && co != OP_SEXT && co != OP_TRUNC { return false; }
    let ls = op(lhs, 0);
    let sty = vals[ls].ty as i32;
    let dty = vals[i].ty as i32;
    if co != OP_BITCAST && (!vc_is_fixed_vec(sty) || !vc_is_fixed_vec(dty)) { return false; }
    if !ty_is_int(ty_scalar(sty)) || !ty_is_int(ty_scalar(dty)) { return false; }
    let invc, nneg, nuw, nsw = vu_lossless_inv_cast(c, sty, co);
    if invc < 0 { return false; }
    let lcc = tv_cast(co, dty, sty, 0, vc_kind, lhs);
    let old = vc_add(tv_arith0(o, dty, vc_kind), lcc);
    let gc = tv_cast(co, dty, sty, 0, vc_kind, -1);
    var nc = vc_add(tv_arith0(o, sty, vc_kind), gc);
    if !vc_has_one_use(lhs) { nc = vc_add(nc, lcc); }
    if nc > old { return false; }
    var nm: u8[>..] = [];
    nm.append(val_name(i));
    nm.append(".inner");
    let nop = vcb_binop(o, ls, invc, nm, 0);
    if vc_is_binop(nop) { vu_copy_ir_flags(nop, i, true); }
    vcw_push_value(nop);
    let ncast = create_inst(co, vals[i].ty, [nop]);
    var fl: u8 = 0;
    if nneg { fl |= FL_NNEG; }
    if nuw { fl |= FL_NUW; }
    if nsw { fl |= FL_NSW; }
    insts[inst_of(ncast)].flags = fl;
    vu_and_ir_flags(ncast, lhs);
    let r = vcb_insert(ncast, "");
    vc_replace(i, r, true);
    return true;
}

// foldBitcastShuffle
fn vc_fold_bitcast_shuffle(i: i32) -> bool {
    if !is_inst_op(i, OP_BITCAST) { return false; }
    let sv = op(i, 0);
    if !vc_is_shuffle(sv) || !vc_has_one_use(sv) { return false; }
    let v0 = op(sv, 0);
    let v1 = op(sv, 1);
    var mask: i32[>..<] = [];
    vc_mask(sv, mask);
    let dty = vals[i].ty as i32;
    let sty = vals[v0].ty as i32;
    if !vc_is_fixed_vec(dty) || !vc_is_fixed_vec(sty) { return false; }
    let des = tt_scalar_bits(dty);
    let ses = tt_scalar_bits(sty);
    if tt_prim_bits(sty) % des != 0 { return false; }
    let unary = is_undef_or_poison(v1);
    if !unary {
        let b0 = vals[vc_peek_bitcasts(v0)].ty as i32;
        let b1 = vals[vc_peek_bitcasts(v1)].ty as i32;
        if !(vc_is_fixed_vec(b0) && ty_elem(b0) == ty_elem(dty)) && !(vc_is_fixed_vec(b1) && ty_elem(b1) == ty_elem(dty)) { return false; }
    }
    var nmask: i32[>..<] = [];
    if des <= ses {
        if ses % des != 0 { return false; }
        vu_narrow_mask(ses / des, mask, nmask);
    } else {
        if des % ses != 0 { return false; }
        if !vu_widen_mask(des / ses, mask, nmask) { return false; }
    }
    let nsrc = tt_prim_bits(sty) / des;
    let nsty = ty_vector(ty_scalar(dty), nsrc, false);
    let osty = ty_vector(ty_scalar(sty), mask.len, false);
    let nops_: i64 = if unary { 1 } else { 2 };
    let sk = if unary { SK_PERMUTESINGLESRC } else { SK_PERMUTETWOSRC };
    let nc = vc_add(tv_shuffle_simple(sk, dty, nsty, nmask, vc_kind), tc_mul(tv_cast(OP_BITCAST, nsty, sty, 0, vc_kind, -1), nops_));
    let old = vc_add(tv_shuffle_simple(sk, osty, sty, mask, vc_kind), tv_cast(OP_BITCAST, dty, osty, 0, vc_kind, -1));
    if nc > old || !tc_valid(nc) { return false; }
    let c0 = vcb_cast(OP_BITCAST, vc_peek_bitcasts(v0), nsty, "");
    let c1 = vcb_cast(OP_BITCAST, vc_peek_bitcasts(v1), nsty, "");
    let s = vcb_shuffle(c0, c1, nmask, "");
    vc_replace(i, s, true);
    return true;
}

// scalarizeVPIntrinsic: VP intrinsics are not ported (fail loudly when one is visited)
fn vc_scalarize_vp_intrinsic(i: i32) -> bool {
    if !is_inst_op(i, OP_CALL) { return false; }
    if !vu_is_vp_intrinsic(inst_iid(i)) { return false; }
    if cb_nargs(i) < 3 { return false; }
    let o0 = cb_arg(i, 0);
    let o1 = cb_arg(i, 1);
    if !vu_is_splat_value(o0, 0) || !vu_is_splat_value(o1, 0) { return false; }
    if vu_get_splat_value(o0) < 0 || vu_get_splat_value(o1) < 0 { return false; }
    // IsAllTrueMask(VPI.getArgOperand(2))
    let ms = vu_get_splat_value(cb_arg(i, 2));
    if ms < 0 || !is_constant(ms) || !is_all_ones_value(ms) { return false; }
    vc_not_ported("scalarizeVPIntrinsic (VPBinOpIntrinsic::isVPBinOp and the functional opcode)");
    return false;
}

// ---------------------------------------------------------------- scalarizeOpOrCmp

fn vc_scalarize_op_or_cmp(i: i32) -> bool {
    let o = iop(i);
    let uo = o == OP_FNEG;
    let bo = is_binary_op(o);
    let ci = o == OP_ICMP || o == OP_FCMP;
    let id = inst_iid(i);
    let ii = o == OP_CALL && tti_is_intrinsic_inst(i);
    if !uo && !bo && !ci && !ii { return false; }
    let has_tti = true;
    if ii {
        if !is_trivially_vectorizable(id) { return false; }
        for k in cb_nargs(i) {
            if vals[cb_arg(i, k)].ty != vals[i].ty && !vu_scalar_op_at_arg(id, k, has_tti) { return false; }
        }
    }
    if ci {
        var u = vals[i].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if is_inst_op(us, OP_SELECT) && op(us, 0) == i { return false; }
            u = uses[u].next;
        }
    }
    var vecs: i32[>..<] = [];
    var scal: i32[>..<] = [];
    var opsv: i32[>..<] = [];
    var has_index = false;
    var index: u64 = 0;
    let nopsv = if ii { cb_nargs(i) } else { nops(i) };
    for k in nopsv {
        let x = op(i, k);
        opsv.push(x);
        let ok, vecc, v, ix = vc_m_ins_c(x);
        if ok && is_constant(vecc) {
            let n = ty_count(vals[x].ty) as u64;
            if n <= ix { return false; }
            if !has_index { has_index = true; index = ix; } else if ix != index { return false; }
            vecs.push(vecc);
            scal.push(v);
        } else if ii && vu_scalar_op_at_arg(id, k, has_tti) {
            vecs.push(x);
            scal.push(x);
        } else if is_constant(x) {
            vecs.push(x);
            scal.push(-1);
        } else {
            return false;
        }
    }
    if !has_index { return false; }
    let vt = vals[i].ty as i32;
    let st = ty_scalar(vt);
    var sc: i64 = 0;
    var vc: i64 = 0;
    if ci {
        let p = inst_pred(i);
        sc = tv_cmpsel(o, st, cmp_result_ty(st), p, vc_kind, 0, 0);
        vc = tv_cmpsel(o, vt, cmp_result_ty(vt), p, vc_kind, 0, 0);
    } else if uo || bo {
        sc = tv_arith0(o, st, vc_kind);
        vc = tv_arith0(o, vt, vc_kind);
    } else {
        var stys: i32[>..<] = [];
        var vtys: i32[>..<] = [];
        for k in cb_nargs(i) { stys.push(st); vtys.push(vt); }
        sc = tv_intrinsic_types(id, st, stys, 0, vc_kind);
        vc = tv_intrinsic_types(id, vt, vtys, 0, vc_kind);
    }
    // SQ(DL, TLI = nullptr, &DT, &AC): no context instruction
    var newvecc: i32 = -1;
    sq_no_tli = true;
    sq_no_dt = false;
    sq_no_ac = false;
    let q = sq_new(-1);
    if ci { newvecc = simplify_cmp(inst_pred(i), vecs[0], vecs[1], q, RECURSION_LIMIT); }
    else if uo { newvecc = simplify_fneg(vecs[0], inst_fmf(i), q); }
    else if bo { newvecc = if is_fp_or_fp_vec(vals[vecs[0]].ty) { simplify_binop_fmf(o, vecs[0], vecs[1], 0, q, RECURSION_LIMIT) } else { simplify_binop(o, vecs[0], vecs[1], q, RECURSION_LIMIT) }; }
    else {
        // simplifyCall(II, Callee, VecCs, SQ)
        let mark = is_ops.len;
        for x in vecs { is_ops.push(x); }
        newvecc = vc_simplify_call(i, mark, vecs.len, q);
        is_ops.resize(mark);
    }
    sq_no_tli = false;
    if newvecc < 0 { return false; }
    let ix = (index & 0xFFFFFFFF) as i64;
    let old0 = vc;
    var old = old0;
    var nc = vc_add(sc, tv_vec_inst(OP_INSERTELEMENT, vt, ix, newvecc, -1, vc_kind));
    for k in opsv.len {
        if scal[k] < 0 || (ii && vu_scalar_op_at_arg(id, k, has_tti)) { continue; }
        let insc = tv_vec_inst(OP_INSERTELEMENT, vt, ix, vecs[k], scal[k], vc_kind);
        old = vc_add(old, insc);
        if !vc_has_one_use(opsv[k]) { nc = vc_add(nc, insc); }
    }
    if old < nc || !tc_valid(nc) { return false; }
    for k in scal.len {
        if scal[k] < 0 { scal[k] = ce_extractelement(vecs[k], vcb_int64(index as i64)); }
    }
    var s: i32 = -1;
    if ci { s = vcb_cmp(inst_pred(i), scal[0], scal[1], ""); }
    else if uo || bo { s = vcb_nary(o, scal, ""); }
    else { s = vcb_intrinsic_rt(st, id, scal, 0, ""); }
    if !is_constant(s) {
        var nm: u8[>..] = [];
        nm.append(val_name(i));
        nm.append(".scalar");
        set_name(s, nm);
    }
    if is_inst(s) { vu_copy_ir_flags(s, i, true); }
    let ins = vcb_insert_elt(newvecc, s, vcb_int64(index as i64), "");
    vc_replace(i, ins, true);
    return true;
}

// simplifyCall(Call, Callee, Args, Q): an intrinsic with the arguments at is_ops[mark..mark + n)
fn vc_simplify_call(c: i32, mark: i64, n: i64, q: SQ) -> i32 {
    let f = called_function(c);
    if f < 0 { return -1; }
    let id = inst_iid(c);
    if id == 0 { return -1; }
    return simplify_intrinsic_args(id, vals[c].ty, mark, n, inst_fmf(c), q, inst_func(c), EB_IGNORE, RM_NEAREST);
}

// ---------------------------------------------------------------- foldExtractedCmps

fn vc_fold_extracted_cmps(i: i32) -> bool {
    if !vc_is_binop(i) || vals[i].ty != T_I1 { return false; }
    let b0 = op(i, 0);
    let b1 = op(i, 1);
    if !vc_is_cmp(b0) || !vc_is_cmp(b1) { return false; }
    let i0 = op(b0, 0);
    let c0 = op(b0, 1);
    let i1 = op(b1, 0);
    let c1 = op(b1, 1);
    if !is_inst(i0) || !is_constant(c0) || !is_inst(i1) || !is_constant(c1) { return false; }
    let okm, pred = vc_matching_pred(b0, b1);
    if !okm { return false; }
    let ok0, x, ix0 = vc_m_ext_c(i0);
    if !ok0 { return false; }
    let ok1, x1, ix1 = vc_m_ext_c(i1);
    if !ok1 || x1 != x { return false; }
    // getShuffleExtract(Ext0, Ext1, CostKind): the cost kind binds to PreferredExtractIndex
    let conv = vc_get_shuffle_extract(i0, i1, vc_kind);
    if conv < 0 { return false; }
    let co = if pred < 32 { OP_FCMP } else { OP_ICMP };
    let vt = vals[x].ty as i32;
    if !vc_is_fixed_vec(vt) { return false; }
    let n = ty_count(vt);
    if ix0 >= n as u64 || ix1 >= n as u64 { return false; }
    let x0 = ix0 as i64;
    let x1i = ix1 as i64;
    let e0c = tv_vec_inst_i(i0, vt, x0, vc_kind);
    let e1c = tv_vec_inst_i(i1, vt, x1i, vc_kind);
    let ity = vals[i0].ty as i32;
    let cmpc = tv_cmpsel(co, ity, cmp_result_ty(ity), pred, vc_kind, 0, 0);
    let old = vc_add(vc_add(vc_add(e0c, e1c), tc_mul(cmpc, 2)), tv_arith0(iop(i), vals[i].ty, vc_kind));
    let cheap_i = if conv == i0 { x1i } else { x0 };
    let exp_i = if conv == i0 { x0 } else { x1i };
    let cmpty = cmp_result_ty(vt);
    var nc = tv_cmpsel(co, vt, cmpty, pred, vc_kind, 0, 0);
    var smask: i32[>..<] = [];
    for k in n { smask.push(-1); }
    smask[cheap_i] = exp_i as i32;
    nc = vc_add(nc, tv_shuffle_simple(SK_PERMUTESINGLESRC, cmpty, cmpty, smask, vc_kind));
    nc = vc_add(nc, tv_arith0(iop(i), cmpty, vc_kind));
    nc = vc_add(nc, tv_vec_inst_i(i0, cmpty, cheap_i, vc_kind));
    nc = vc_add(nc, if vc_has_one_use(i0) { 0 } else { e0c });
    nc = vc_add(nc, if vc_has_one_use(i1) { 0 } else { e1c });
    if old < nc || !tc_valid(nc) { return false; }
    var cs: i32[>..<] = [];
    for k in n { cs.push(c_poison(ty_elem(vt))); }
    cs[x0] = c0;
    cs[x1i] = c1;
    let vcmp = vcb_cmp(pred, x, c_aggregate(vt, cs), "");
    let sh = vc_create_shift_shuffle(vcmp, exp_i, cheap_i);
    let l = if conv == i0 { sh } else { vcmp };
    let r = if conv == i0 { vcmp } else { sh };
    let vl = vcb_binop(iop(i), l, r, "", 0);
    let ne = vcb_extract(vl, vcb_int64(cheap_i), "");
    vc_replace(i, ne, true);
    return true;
}

// CmpPredicate::getMatching(CmpPredicate::get(A), CmpPredicate::get(B)) as a plain predicate
fn vc_matching_pred(a: i32, b: i32) -> bool, i64 {
    let pa = inst_pred(a);
    let pb = inst_pred(b);
    if pa == pb { return true, pa; }
    if pa < 32 || pb < 32 { return false, 0; }
    let sa = iop(a) == OP_ICMP && (insts[inst_of(a)].flags & FL_SAMESIGN) != 0;
    let sb = iop(b) == OP_ICMP && (insts[inst_of(b)].flags & FL_SAMESIGN) != 0;
    if sa && pa == vc_flip_signedness(pb) { return true, pb; }
    if sb && pb == vc_flip_signedness(pa) { return true, pa; }
    return false, 0;
}
// ICmpInst::getFlippedSignednessPredicate (relational predicates)
fn vc_flip_signedness(p: i64) -> i64 {
    if p >= VC_UGT && p <= VC_ULE { return p + 4; }
    if p >= VC_SGT && p <= VC_SLE { return p - 4; }
    return p;
}

// ---------------------------------------------------------------- foldSelectsFromBitcast

fn vc_fold_selects_from_bitcast(i: i32) -> bool {
    if !is_inst_op(i, OP_BITCAST) { return false; }
    let svt = vals[op(i, 0)].ty as i32;
    let dvt = vals[i].ty as i32;
    if !vc_is_fixed_vec(svt) || !vc_is_fixed_vec(dvt) { return false; }
    let se = ty_elem(svt);
    let de = ty_elem(dvt);
    let sb = tt_prim_bits(se);
    let db = tt_prim_bits(de);
    if sb != 32 && sb != 64 { return false; }
    if !ty_is_int(de) || db >= sb { return false; }
    let condty = cmp_result_ty(de);
    let vcondty = cmp_result_ty(svt);
    let ssc = tv_cmpsel(OP_SELECT, de, condty, PRED_BAD_ICMP, vc_kind, 0, 0);
    let vsc = tv_cmpsel(OP_SELECT, svt, vcondty, PRED_BAD_ICMP, vc_kind, 0, 0);
    if !tc_valid(ssc) || ssc == 0 { return false; }
    let minsel = vsc / ssc + 1;
    if vc_num_uses(i) < minsel { return false; }
    // CondToSelects: DenseMap<Value *, SmallVector<SelectInst *>>, iterated in pointer-hash order in LLVM
    var conds: i32[>..<] = [];
    var sels: i32[>..<] = [];      // (cond index, select) pairs flattened: cond index, select
    var u = vals[i].first_use;
    while u >= 0 {
        let e = uses[u].user;
        u = uses[u].next;
        if !is_inst_op(e, OP_EXTRACTELEMENT) { continue; }
        var w = vals[e].first_use;
        while w >= 0 {
            let s = uses[w].user;
            w = uses[w].next;
            if is_inst_op(s, OP_SELECT) && op(s, 1) == e && m_zero(op(s, 2)) && vals[op(s, 0)].ty == T_I1 {
                let c = op(s, 0);
                var ci: i64 = -1;
                for k in conds.len { if conds[k] == c { ci = k; } }
                if ci < 0 { ci = conds.len; conds.push(c); }
                sels.push(ci as i32);
                sels.push(s);
            }
        }
    }
    if conds.len == 0 { return false; }
    var ngroups: i64 = 0;
    for k in conds.len {
        var cnt: i64 = 0;
        var j: i64 = 0;
        while j < sels.len { if sels[j] as i64 == k { cnt++; } j += 2; }
        if cnt >= minsel { ngroups++; }
    }
    if ngroups > 1 { vc_not_ported("foldSelectsFromBitcast with several conditions (DenseMap order)"); }
    var changed = false;
    let srcv = op(i, 0);
    for k in conds.len {
        var cnt: i64 = 0;
        var j: i64 = 0;
        while j < sels.len { if sels[j] as i64 == k { cnt++; } j += 2; }
        if cnt < minsel { continue; }
        let c = conds[k];
        var ipos = inst_next(i);
        if is_inst(c) && dt_value_dominates_inst(i, c) { ipos = inst_next(c); }
        vcb_set_it(ipos, false);
        let vsel = vcb_select(c, srcv, c_null(svt), 0, "");
        let nbc = vcb_cast(OP_BITCAST, vsel, dvt, "");
        j = 0;
        while j < sels.len {
            if sels[j] as i64 == k {
                let s = sels[j + 1];
                let e = op(s, 1);
                let idx = op(e, 1);
                vcb_set(s);
                let ne = vcb_extract(nbc, idx, "");
                vc_replace(s, ne, true);
                changed = true;
            }
            j += 2;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- foldBinopOfReductions

// analyzeCostOfVecReduction: (CostBeforeReduction, CostAfterReduction)
fn vc_analyze_cost_of_vec_reduction(ii: i32, before0: i64) -> i64, i64 {
    let red = op(ii, 0);
    let vrt = vals[red].ty as i32;
    let ro = vu_arith_reduction_instruction(inst_iid(ii));
    if is_inst(red) && (iop(red) == OP_ZEXT || iop(red) == OP_SEXT) {
        let unsigned = iop(red) == OP_ZEXT;
        let ext = vals[op(red, 0)].ty as i32;
        let b = tv_cast(iop(red), vrt, ext, 0, vc_kind, red);
        let a = tv_extended_reduction(ro, unsigned, vals[ii].ty, ext, 0, true, vc_kind);
        return b, a;
    }
    // reduce.add(ext(mul(ext(A), ext(B)))): every zext/sext RedOp took the case above
    return before0, tv_arith_reduction(ro, vrt, false, vc_kind);
}

fn vc_fold_binop_of_reductions(i: i32) -> bool {
    let bo = iop(i);
    var rid = vu_reduction_for_binop(bo);
    if bo == OP_SUB { rid = IID_vector_reduce_add; }
    if rid == 0 { return false; }
    if rid == IID_vector_reduce_fadd || rid == IID_vector_reduce_fmul { return false; }
    fn arg_of(v: i32, id: i32) -> i32 {
        if !is_inst_op(v, OP_CALL) || !tti_is_intrinsic_inst(v) { return -1; }
        if inst_iid(v) == id && vc_has_one_use(v) { return cb_arg(v, 0); }
        return -1;
    }
    let v0 = arg_of(op(i, 0), rid);
    if v0 < 0 { return false; }
    let v1 = arg_of(op(i, 1), rid);
    if v1 < 0 { return false; }
    let vty = vals[v0].ty as i32;
    if vals[v1].ty != vty { return false; }
    let ii0 = op(i, 0);
    let ii1 = op(i, 1);
    let ro = vu_arith_reduction_instruction(inst_iid(ii0));
    let ob0, r0 = vc_analyze_cost_of_vec_reduction(ii0, 0);
    let ob1, r1 = vc_analyze_cost_of_vec_reduction(ii1, 0);
    let old = vc_add(vc_add(r0, r1), tv_inst_cost(i, vc_kind));
    let nc = vc_add(vc_add(vc_add(ob0, ob1), tv_arith0(bo, vty, vc_kind)), tv_arith_reduction(ro, vty, false, vc_kind));
    if nc >= old || !tc_valid(nc) { return false; }
    var vbo: i32 = -1;
    if bo == OP_OR { vbo = vcb_binop(OP_OR, v0, v1, "", if op_disjoint(i) { FL_DISJOINT } else { 0 }); }
    else { vbo = vcb_binop(bo, v0, v1, "", 0); }
    let rdx = vcb_intrinsic(rid as i64, [vty], [vbo], 0, "");
    vc_replace(i, rdx, true);
    return true;
}

// ---------------------------------------------------------------- scalarizing memory accesses

// isMemModifiedBetween(Begin, End, Loc, AA)
fn vc_is_mem_modified_between(begin: i32, end: i32, loc: ML) -> bool {
    var n: i64 = 0;
    let lim = vc_max_scan();
    var x = begin;
    while x >= 0 && x != end {
        if (aa_inst_loc_mr_simple(x, loc) & MR_MOD) != 0 { return true; }
        n++;
        if n > lim { return true; }
        x = inst_next(x);
    }
    return false;
}

// canScalarizeAccess(VecTy, Idx, SQ): 0 unsafe, 1 safe, 2 safe with a freeze of the returned value
fn vc_can_scalarize_access(vt: i32, idx: i32, cxt: i32) -> i64, i32 {
    let ne = ty_count(vt);
    let iw = tt_scalar_bits(vals[idx].ty);
    if vals[idx].kind == VK_CINT {
        if ap_ult_u64(ci_ap(idx), ne as u64) { return 1, -1; }
        return 0, -1;
    }
    // isUIntN(IntWidth, NumElements)
    if iw < 64 && (ne as u64) >= ((1 as u64) << (iw as u64)) { return 0, -1; }
    let valid = rg_new(ap_zero(iw), ap_u64(ne as u64, iw));
    var irange = rg_full(iw);
    sq_no_dt = false;
    sq_no_ac = false;
    sq_no_tli = true;
    kb_cxt = cxt;
    if is_guaranteed_not_to_be_poison(idx, cxt, 0) {
        kb_cxt = cxt;
        let r = compute_constant_range(idx, false, true, 0);
        sq_no_tli = false;
        if rg_contains(valid, r) { return 1, -1; }
        return 0, -1;
    }
    sq_no_tli = false;
    var base: i32 = -1;
    if is_inst_op(idx, OP_AND) && vals[op(idx, 1)].kind == VK_CINT {
        base = op(idx, 0);
        irange = rg_and(irange, rg_single(ci_ap(op(idx, 1))));
    } else if is_inst_op(idx, OP_UREM) && vals[op(idx, 1)].kind == VK_CINT {
        base = op(idx, 0);
        irange = rg_urem(irange, rg_single(ci_ap(op(idx, 1))));
    }
    if rg_contains(valid, irange) { return 2, base; }
    return 0, -1;
}

// ScalarizationResult::freeze(Builder, UserI)
fn vc_freeze_index(tofreeze: i32, user: i32) {
    let sbb = vcb_bb;
    let spos = vcb_pos;
    let shead = vcb_head;
    let sdl = vcb_dl;
    vcb_set(user);
    var nm: u8[>..] = [];
    nm.append(val_name(tofreeze));
    nm.append(".frozen");
    let fr = vcb_freeze(tofreeze, nm);
    for k in nops(user) { if op(user, k) == tofreeze { set_op(user, k, fr); } }
    vcb_bb = sbb; vcb_pos = spos; vcb_head = shead; vcb_dl = sdl;
}

// computeAlignmentAfterScalarization(VectorAlignment, ScalarType, Idx, DL)
fn vc_align_after_scalarization(va: i64, sty: i32, idx: i32) -> i64 {
    if vals[idx].kind == VK_CINT { return tt_common_align(va, (ap_zext64(ci_ap(idx)) as i64) * dl_store_size(sty)); }
    return tt_common_align(va, dl_store_size(sty));
}

fn vc_type_size_equals_store_size(t: i32) -> bool { dl_size_bits(t) == dl_store_size(t) * 8 }

// foldSingleElementStore
fn vc_fold_single_element_store(i: i32) -> bool {
    if !tv_allow_vector_element_indexing_using_gep() { return false; }
    let v = op(i, 0);
    if !ld_is_simple(i) || !ty_is_vector(vals[v].ty) { return false; }
    if !is_inst_op(v, OP_INSERTELEMENT) || !is_inst(op(v, 0)) { return false; }
    let src = op(v, 0);
    let ne = op(v, 1);
    let idx = op(v, 2);
    if !is_inst_op(src, OP_LOAD) { return false; }
    let ld = src;
    let vt = vals[v].ty as i32;
    let saddr = strip_ptr_casts(op(ld, 0));
    if !ld_is_simple(ld) || inst_parent(ld) != inst_parent(i) || !vc_type_size_equals_store_size(ty_scalar(vals[ld].ty)) ||
       saddr != strip_ptr_casts(op(i, 1)) { return false; }
    if vc_is_mem_modified_between(ld, i, ml_get(i)) { return false; }
    let st, tofreeze = vc_can_scalarize_access(vt, idx, ld);
    if st == 0 { return false; }
    vcw_push(ld);
    if st == 2 { vc_freeze_index(tofreeze, idx); }
    let g = vcb_inbounds_gep(vt, op(i, 1), [c_int(vals[idx].ty, 0), idx], "");
    let nsi = vcb_store(ne, g);
    vc_copy_metadata(nsi, i);
    let mx = if vc_align_of(i) > vc_align_of(ld) { vc_align_of(i) } else { vc_align_of(ld) };
    vc_set_align(nsi, vc_align_after_scalarization(mx, vals[ne].ty, idx));
    vc_replace(i, nsi, true);
    vc_erase(i);
    return true;
}

// Instruction::copyMetadata(SrcInst) (all kinds; !dbg too)
fn vc_copy_metadata(dst: i32, src: i32) {
    let dl = inst_get_md(src, 0);
    if dl >= 0 { inst_set_md(dst, 0, dl); }
    let si = inst_of(src);
    var kinds: i32[>..<] = [];
    var nodes: i32[>..<] = [];
    for k in insts[si].nmd { kinds.push(md_att[insts[si].md + 2 * k]); nodes.push(md_att[insts[si].md + 2 * k + 1]); }
    for k in kinds.len { if kinds[k] != 0 { inst_set_md(dst, kinds[k], nodes[k]); } }
}

// scalarizeLoad
fn vc_scalarize_load(i: i32) -> bool {
    if !is_inst_op(i, OP_LOAD) { return false; }
    let ptr = op(i, 0);
    let vt = vals[i].ty as i32;
    if !ld_is_simple(i) || !vc_type_size_equals_store_size(ty_scalar(vt)) { return false; }
    var all_ext = true;
    var all_bc = true;
    var last = i;
    var nchecked: i64 = 0;
    let lim = vc_max_scan();
    var u = vals[i].first_use;
    while u >= 0 {
        let ui = uses[u].user;
        u = uses[u].next;
        if !is_inst(ui) || inst_parent(ui) != inst_parent(i) { return false; }
        if vals[ui].first_use < 0 { return false; }
        if iop(ui) != OP_EXTRACTELEMENT { all_ext = false; }
        if iop(ui) != OP_BITCAST { all_bc = false; }
        if comes_before(last, ui) {
            var x = inst_next(i);
            while x >= 0 && x != ui {
                if nchecked == lim || inst_may_write_memory(x) { return false; }
                nchecked++;
                x = inst_next(x);
            }
            last = ui;
        }
    }
    if all_ext { return vc_scalarize_load_extract(i, vt, ptr); }
    if all_bc { return vc_scalarize_load_bitcast(i, vt, ptr); }
    return false;
}

// scalarizeLoadExtract
fn vc_scalarize_load_extract(li: i32, vt: i32, ptr: i32) -> bool {
    if !tv_allow_vector_element_indexing_using_gep() { return false; }
    var nf_ext: i32[>..<] = [];     // NeedFreeze: extract -> value to freeze
    var nf_val: i32[>..<] = [];
    let as_ = ptr_as(vals[op(li, 0)].ty);
    var orig = tv_mem(OP_LOAD, vt, vc_align_of(li), as_, vc_kind);
    var sc: i64 = 0;
    var u = vals[li].first_use;
    while u >= 0 {
        let ui = uses[u].user;
        u = uses[u].next;
        let st, tf = vc_can_scalarize_access(vt, op(ui, 1), li);
        if st == 0 { return false; }
        if st == 2 {
            var seen = false;
            for e in nf_ext { if e == ui { seen = true; } }
            if !seen { nf_ext.push(ui); nf_val.push(tf); }
        }
        let ix = op(ui, 1);
        var idx: i64 = -1;
        if vals[ix].kind == VK_CINT { idx = (ap_zext64(ci_ap(ix)) & 0xFFFFFFFF) as i64; }
        orig = vc_add(orig, tv_vec_inst(OP_EXTRACTELEMENT, vt, idx, -1, -1, vc_kind));
        sc = vc_add(sc, tv_mem(OP_LOAD, ty_elem(vt), 1, as_, vc_kind));
        sc = vc_add(sc, tv_address_computation(vals[op(li, 0)].ty, vc_kind));
    }
    if sc >= orig { return false; }
    vcw_push(li);
    let et = ty_elem(vt);
    // the users are rewritten in use-list order; replaceValue(*EI, *NewLoad, false) moves no use of the load
    var users: i32[>..<] = [];
    u = vals[li].first_use;
    while u >= 0 { users.push(uses[u].user); u = uses[u].next; }
    for ei in users {
        let idx = op(ei, 1);
        for k in nf_ext.len { if nf_ext[k] == ei { vc_freeze_index(nf_val[k], idx); } }
        vcb_set(ei);
        let idx2 = op(ei, 1);
        let g = vcb_inbounds_gep(vt, ptr, [c_int(T_I32, 0), idx2], "");
        var nm: u8[>..] = [];
        nm.append(val_name(ei));
        nm.append(".scalar");
        let nl = vcb_load(et, g, dl_align(et, true), nm);
        vc_set_align(nl, vc_align_after_scalarization(vc_align_of(li), et, idx2));
        if vals[idx2].kind == VK_CINT {
            let off = (ap_zext64(ci_ap(idx2)) as i64) * dl_store_size(et);
            aa_set(nl, aa_adjust(aa_get(li), off, et));
        }
        vc_replace(ei, nl, false);
    }
    return true;
}

// scalarizeLoadBitcast
fn vc_scalarize_load_bitcast(li: i32, vt: i32, ptr: i32) -> bool {
    let as_ = ptr_as(vals[op(li, 0)].ty);
    var orig = tv_mem(OP_LOAD, vt, vc_align_of(li), as_, vc_kind);
    var target: i32 = -1;
    let vbw = dl_size_bits(vt);
    var u = vals[li].first_use;
    while u >= 0 {
        let bc = uses[u].user;
        u = uses[u].next;
        let dt = vals[bc].ty as i32;
        if !ty_is_int(dt) && !ty_is_fp(dt) { return false; }
        if dl_size_bits(dt) != vbw { return false; }
        if target < 0 { target = dt; } else if target != dt { return false; }
        orig = vc_add(orig, tv_cast(OP_BITCAST, target, vt, tv_cast_context_hint(bc), vc_kind, bc));
    }
    if target < 0 { return false; }
    let sc = tv_mem(OP_LOAD, target, vc_align_of(li), as_, vc_kind);
    if sc >= orig { return false; }
    vcw_push(li);
    vcb_set(li);
    var nm: u8[>..] = [];
    nm.append(val_name(li));
    nm.append(".scalar");
    let sl = vcb_load(target, ptr, dl_align(target, true), nm);
    vc_set_align(sl, vc_align_of(li));
    vc_copy_metadata(sl, li);
    var users: i32[>..<] = [];
    u = vals[li].first_use;
    while u >= 0 { users.push(uses[u].user); u = uses[u].next; }
    for bc in users { vc_replace(bc, sl, false); }
    return true;
}

// scalarizeExtExtract
fn vc_scalarize_ext_extract(i: i32) -> bool {
    if !tv_allow_vector_element_indexing_using_gep() { return false; }
    if !is_inst_op(i, OP_ZEXT) { return false; }
    let sty = vals[op(i, 0)].ty as i32;
    if !vc_is_fixed_vec(sty) { return false; }
    let dty = vals[i].ty as i32;
    let sdt = ty_elem(dty);
    if dl_size_bits(sty) != dl_size_bits(sdt) { return false; }
    var vcost = tv_cast(OP_ZEXT, dty, sty, 0, vc_kind, i);
    var cnt: i64 = 0;
    var lane0 = false;
    var u = vals[i].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        let ok, vv, idx = vc_m_ext_c(us);
        if !ok { return false; }
        if vals[us].first_use < 0 { continue; }
        cnt++;
        if idx == 0 { lane0 = true; }
        vcost = vc_add(vcost, tv_vec_inst(OP_EXTRACTELEMENT, dty, (idx & 0xFFFFFFFF) as i64, -1, -1, vc_kind));
    }
    let nconst = OK_NONUNIFORM_CONST * 4;
    let scost = vc_add(tc_mul(tv_arith(OP_AND, sdt, vc_kind, 0, nconst), cnt),
                       tc_mul(tv_arith(OP_LSHR, sdt, vc_kind, 0, nconst), cnt - (if lane0 { 1 } else { 0 })));
    if scost > vcost { return false; }
    var sv = op(i, 0);
    sq_no_dt = false;
    sq_no_ac = false;
    let gnp = is_guaranteed_not_to_be_poison(sv, if is_inst(sv) { sv } else { -1 }, 0);
    if !gnp {
        vs_clear(VS_PASS0);
        var nlanes: i64 = 0;
        var all_ub = true;
        var last: i32 = -1;
        let ebb = inst_parent(i);
        u = vals[i].first_use;
        while u >= 0 {
            let e = uses[u].user;
            u = uses[u].next;
            if inst_parent(e) != ebb || !program_undefined_if_undef_or_poison(e, true) { all_ub = false; break; }
            let ix = op(e, 1);
            if vs_add(VS_PASS0, ix) { nlanes++; }
            if last < 0 || comes_before(last, e) { last = e; }
        }
        if nlanes != ty_count(dty) || !all_ub || !vc_transfers_execution(i, last) {
            sv = vcb_freeze(sv, "");
        }
    }
    sv = vcb_cast(OP_BITCAST, sv, ty_int(dl_size_bits(sty)), "");
    let seb = dl_size_bits(ty_elem(sty));
    let tb = dl_size_bits(sty);
    let pty = ty_int(tb);
    let maskc = c_int_ap(pty, ap_low_bits(tb, seb));
    var users: i32[>..<] = [];
    u = vals[i].first_use;
    while u >= 0 { users.push(uses[u].user); u = uses[u].next; }
    for e in users {
        let ok, idx = vc_cint_u64(op(e, 1));
        let sh = if dl_big_endian { tb - seb - (idx as i64) * seb } else { (idx as i64) * seb };
        let ls = vcb_binop(OP_LSHR, sv, vc_cint(vals[sv].ty, sh as u64), "", 0);
        let a = vcb_binop(OP_AND, ls, maskc, "", 0);
        rauw(e, a);
    }
    return true;
}

// isGuaranteedToTransferExecutionToSuccessor(Begin, End, ScanLimit = 32)
fn vc_transfers_execution(begin: i32, end: i32) -> bool {
    var lim: i64 = 32;
    var x = begin;
    while x >= 0 && x != end {
        lim--;
        if lim == 0 { return false; }
        if !guaranteed_to_transfer(x) { return false; }
        x = inst_next(x);
    }
    return true;
}

// ---------------------------------------------------------------- foldConcatOfBoolMasks

// m_OneUse(m_ZExt(m_OneUse(m_BitCast(m_Value(Src))))) or the same under m_OneUse(m_Shl(.., m_ConstantInt(ShAmt)))
fn vc_match_zext_bitcast(x: i32) -> bool, i32, u64 {
    fn zb(v: i32) -> i32 {
        if !vc_has_one_use(v) || !is_inst_op(v, OP_ZEXT) { return -1; }
        let b = op(v, 0);
        if !vc_has_one_use(b) || !is_inst_op(b, OP_BITCAST) { return -1; }
        return op(b, 0);
    }
    let s = zb(x);
    if s >= 0 { return true, s, 0; }
    if !vc_has_one_use(x) || !is_inst_op(x, OP_SHL) { return false, -1, 0; }
    let s2 = zb(op(x, 0));
    if s2 < 0 { return false, -1, 0; }
    let ok, c = vc_cint_u64(op(x, 1));
    if !ok { return false, -1, 0; }
    return true, s2, c;
}

fn vc_fold_concat_of_bool_masks(i: i32) -> bool {
    let ty = vals[i].ty as i32;
    if !ty_is_int(ty) { return false; }
    if dl_big_endian { return false; }
    // m_DisjointOr(m_Instruction(X), m_Instruction(Y))
    if !is_inst_op(i, OP_OR) || !op_disjoint(i) { return false; }
    var x = op(i, 0);
    var y = op(i, 1);
    if !is_inst(x) || !is_inst(y) { return false; }
    let okx, sx0, ax0 = vc_match_zext_bitcast(x);
    if !okx { return false; }
    let oky, sy0, ay0 = vc_match_zext_bitcast(y);
    if !oky { return false; }
    var sx = sx0;
    var sy = sy0;
    var ax = ax0;
    var ay = ay0;
    if ax > ay {
        let t = x; x = y; y = t;
        let t2 = sx; sx = sy; sy = t2;
        let t3 = ax; ax = ay; ay = t3;
    }
    let diff = ay - ax;
    let nshl: i64 = (if ax > 0 { 1 } else { 0 }) + (if ay > 0 { 1 } else { 0 });
    let bw = ty_bits(ty);
    let mty = vals[sx].ty as i32;
    if !vc_is_fixed_vec(mty) || vals[sx].ty != vals[sy].ty || ty_elem(mty) != T_I1 || (ty_count(mty) as u64) != diff ||
       ty_count(mty) > bw / 2 { return false; }
    let cty = ty_vector(T_I1, ty_count(mty) * 2, false);
    let city = ty_int(ty_count(cty));
    let mity = ty_int(diff as i64);
    var cmask: i32[>..<] = [];
    for k in ty_count(cty) { cmask.push(k as i32); }
    var old: i64 = 0;
    old = vc_add(old, tv_arith0(OP_OR, ty, vc_kind));
    old = vc_add(old, tc_mul(tv_arith0(OP_SHL, ty, vc_kind), nshl));
    old = vc_add(old, tc_mul(tv_cast(OP_ZEXT, ty, mity, 0, vc_kind, -1), 2));
    old = vc_add(old, tc_mul(tv_cast(OP_BITCAST, mity, mty, 0, vc_kind, -1), 2));
    var nc: i64 = 0;
    nc = vc_add(nc, tv_shuffle_simple(SK_PERMUTETWOSRC, cty, mty, cmask, vc_kind));
    nc = vc_add(nc, tv_cast(OP_BITCAST, city, cty, 0, vc_kind, -1));
    if ty != city { nc = vc_add(nc, tv_cast(OP_ZEXT, ty, city, 0, vc_kind, -1)); }
    if ax > 0 { nc = vc_add(nc, tv_arith0(OP_SHL, ty, vc_kind)); }
    if nc > old { return false; }
    let cc = vcb_shuffle(sx, sy, cmask, "");
    vcw_push_value(cc);
    var r = vcb_cast(OP_BITCAST, cc, city, "");
    if ty != city {
        vcw_push_value(r);
        r = vcb_cast(OP_ZEXT, r, ty, "");
    }
    if ax > 0 {
        vcw_push_value(r);
        r = vcb_binop(OP_SHL, r, vc_cint(vals[r].ty, ax), "", 0);
    }
    vc_replace(i, r, true);
    return true;
}
