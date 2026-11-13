// VPlan core: the data model (blocks, values, recipes as rows of one Vp_Plan), VPValue/VPUser/VPDef operations,
// recipe list operations, VPBlockUtils, CFG traversals, VPlan creation/duplication, VPBuilder, VPDominatorTree.
// Ported from llvm/lib/Transforms/Vectorize/VPlan.h, VPlanValue.h, VPlan.cpp (block/value/plan parts), VPlanCFG.h,
// VPlanUtils.h (VPBlockUtils), LoopVectorizationPlanner.h (VPBuilder), VPlanDominatorTree.h (LLVM 23.1.5).
// Design: DESIGN.md "LoopVectorize and VPlan".

Vp_Blk :: u32;
Vp_Val :: u32;
Vp_Rec :: u32;

vp_unported :: (what: string) { fatal("loop-vectorize: % is not supported yet", what); }

// ---------------------------------------------------------------- kinds

Vp_Block_Kind :: enum u8 { REGION; BASIC; IR_BASIC; }

// VPRecipeBase::VPRecipeTy, in LLVM's order
Vp_Kind :: enum u8 {
    BRANCH_ON_MASK; DERIVED_IV; EXPAND_SCEV; EXPRESSION; IR_INSTRUCTION; INSTRUCTION; INTERLEAVE_EVL; INTERLEAVE;
    REDUCTION_EVL; REDUCTION; REPLICATE; SCALAR_IV_STEPS; VECTOR_POINTER; VECTOR_END_POINTER; WIDEN_CALL;
    WIDEN_CANONICAL_IV; WIDEN_CAST; WIDEN_GEP; WIDEN_INTRINSIC; WIDEN_MEM_INTRINSIC; WIDEN_LOAD_EVL; WIDEN_LOAD;
    WIDEN_STORE_EVL; WIDEN_STORE; WIDEN; BLEND; HISTOGRAM;
    WIDEN_PHI; PRED_INST_PHI; CURRENT_ITERATION_PHI; ACTIVE_LANE_MASK_PHI; FIRST_ORDER_RECURRENCE_PHI;
    WIDEN_INT_OR_FP_INDUCTION; WIDEN_POINTER_INDUCTION; REDUCTION_PHI;
}
VP_FIRST_PHI :: Vp_Kind.WIDEN_PHI;
VP_FIRST_HEADER_PHI :: Vp_Kind.CURRENT_ITERATION_PHI;
VP_LAST_HEADER_PHI :: Vp_Kind.REDUCTION_PHI;
VP_LAST_PHI :: Vp_Kind.REDUCTION_PHI;

// VPInstruction opcodes beyond the IR opcodes (Instruction::OtherOpsEnd + 1 ...)
VPI_FIRST_ORDER_RECURRENCE_SPLICE :: 100;
VPI_NOT :: 101; VPI_ACTIVE_LANE_MASK :: 102; VPI_EXPLICIT_VECTOR_LENGTH :: 103; VPI_INCOMING_ALIAS_MASK :: 104;
VPI_CALCULATE_TRIP_COUNT_MINUS_VF :: 105; VPI_CANONICAL_IV_INCREMENT_FOR_PART :: 106; VPI_BRANCH_ON_COUNT :: 107;
VPI_BRANCH_ON_COND :: 108; VPI_BRANCH_ON_TWO_CONDS :: 109; VPI_BROADCAST :: 110; VPI_BUILD_STRUCT_VECTOR :: 111;
VPI_BUILD_VECTOR :: 112; VPI_UNPACK :: 113; VPI_COMPUTE_REDUCTION_RESULT :: 114; VPI_EXTRACT_LAST_PART :: 115;
VPI_EXTRACT_LAST_LANE :: 116; VPI_EXTRACT_PENULTIMATE_ELEMENT :: 117; VPI_LOGICAL_AND :: 118; VPI_LOGICAL_OR :: 119;
VPI_NUM_ACTIVE_LANES :: 120; VPI_PTR_ADD :: 121; VPI_WIDE_PTR_ADD :: 122; VPI_ANY_OF :: 123;
VPI_FIRST_ACTIVE_LANE :: 124; VPI_LAST_ACTIVE_LANE :: 125; VPI_REVERSE :: 126; VPI_REDUCTION_START_VECTOR :: 127;
VPI_EXTRACT_LANE :: 128; VPI_RESUME_FOR_EPILOGUE :: 129; VPI_EXTRACT_LAST_ACTIVE :: 130; VPI_EXITING_IV_VALUE :: 131;
VPI_MASKED_COND :: 132; VPI_WIDE_IV_STEP :: 133; VPI_STEP_VECTOR :: 134; VPI_INTRINSIC :: 135;

vp_opc :: inline (o: Opcode) -> u16 { return cast(u16) o; }
vp_is_ir_opcode :: inline (o: u16) -> bool { return o < 100; }
vp_ir_opcode :: inline (o: u16) -> Opcode { return cast(Opcode) o; }
vp_opcode_is_cast :: (o: u16) -> bool { return vp_is_ir_opcode(o) && is_cast_op(vp_ir_opcode(o)); }

// ---------------------------------------------------------------- VPIRFlags

Vp_Op_Type :: enum u8 { CMP; FCMP; OVERFLOWING_BINOP; TRUNC; DISJOINT_OP; POSSIBLY_EXACT_OP; GEP_OP; FP_MATH_OP; NON_NEG_OP; REDUCTION_OP; OTHER; }
Vp_Flags :: struct {
    optype: Vp_Op_Type = .OTHER;
    nuw: bool; nsw: bool;          // OVERFLOWING_BINOP, TRUNC
    disjoint: bool;                // DISJOINT_OP
    exact: bool;                   // POSSIBLY_EXACT_OP
    nneg: bool;                    // NON_NEG_OP
    gep: u32;                      // GEP_OP: GEPNoWrapFlags as the IR's F_INBOUNDS | F_NUSW | F_NUW bits
    fmf: u32;                      // FP_MATH_OP, FCMP, REDUCTION_OP
    pred: u8;                      // CMP, FCMP
    rdx_kind: Recur_Kind;          // REDUCTION_OP
    rdx_ordered: bool; rdx_in_loop: bool;
}
vpf_wrap :: (nuw: bool, nsw: bool) -> Vp_Flags { f: Vp_Flags; f.optype = .OVERFLOWING_BINOP; f.nuw = nuw; f.nsw = nsw; return f; }
vpf_trunc :: (nuw: bool, nsw: bool) -> Vp_Flags { f: Vp_Flags; f.optype = .TRUNC; f.nuw = nuw; f.nsw = nsw; return f; }
vpf_cmp :: (pred: u8) -> Vp_Flags { f: Vp_Flags; f.optype = .CMP; f.pred = pred; return f; }
vpf_fcmp :: (pred: u8, fmf: u32) -> Vp_Flags { f: Vp_Flags; f.optype = .FCMP; f.pred = pred; f.fmf = fmf; return f; }
vpf_fmf :: (fmf: u32) -> Vp_Flags { f: Vp_Flags; f.optype = .FP_MATH_OP; f.fmf = fmf; return f; }
vpf_disjoint :: (d: bool) -> Vp_Flags { f: Vp_Flags; f.optype = .DISJOINT_OP; f.disjoint = d; return f; }
vpf_nneg :: (n: bool) -> Vp_Flags { f: Vp_Flags; f.optype = .NON_NEG_OP; f.nneg = n; return f; }
vpf_exact :: (e: bool) -> Vp_Flags { f: Vp_Flags; f.optype = .POSSIBLY_EXACT_OP; f.exact = e; return f; }
vpf_gep :: (g: u32) -> Vp_Flags { f: Vp_Flags; f.optype = .GEP_OP; f.gep = g; return f; }
vpf_reduction :: (k: Recur_Kind, ordered: bool, in_loop: bool, fmf: u32) -> Vp_Flags {
    f: Vp_Flags; f.optype = .REDUCTION_OP; f.rdx_kind = k; f.rdx_ordered = ordered; f.rdx_in_loop = in_loop; f.fmf = fmf; return f;
}

// ---------------------------------------------------------------- rows

Vp_Block_Row :: struct {
    kind: Vp_Block_Kind;
    name: string;
    parent: Vp_Blk = NONE;            // VPRegionBlock *Parent
    preds: [..] Vp_Blk;
    succs: [..] Vp_Blk;
    first: Vp_Rec = NONE;             // recipe list (basic blocks)
    last: Vp_Rec = NONE;
    irbb: Value_Id = NONE;            // VPIRBasicBlock
    entry: Vp_Blk = NONE;             // regions
    exiting: Vp_Blk = NONE;
    can_iv: Vp_Val = NONE;            // VPCanonicalIVInfo (NONE: replicate region)
    header_mask: Vp_Val = NONE;
    can_iv_nuw := true;
    dead: bool;
}

Vp_Value_Kind :: enum u8 { IR; SYMBOLIC; REGION; SINGLE_DEF; MULTI_DEF; }
Vp_Value_Row :: struct {
    kind: Vp_Value_Kind;
    uv: Value_Id = NONE;              // UnderlyingVal
    ty: Type_Id = NONE;               // scalar type (VPRecipeValue::Ty / VPSymbolicValue::Ty)
    users: [..] Vp_Rec;
    def: Vp_Rec = NONE;               // SINGLE_DEF / MULTI_DEF (NONE for a multi-def value removed from its def)
    materialized: bool;               // SYMBOLIC / REGION
    region: Vp_Blk = NONE;            // REGION: the defining region
    dl: Md_Id = NONE;                 // REGION
}

Vp_Recipe_Row :: struct {
    kind: Vp_Kind;
    parent: Vp_Blk = NONE;
    prev: Vp_Rec = NONE;
    next: Vp_Rec = NONE;
    ops: [..] Vp_Val;
    def: Vp_Val = NONE;               // single-def recipes
    defs: [..] Vp_Val;                // multi-def recipes (interleave groups)
    dl: Md_Id = NONE;
    opcode: u16;                      // INSTRUCTION, WIDEN, WIDEN_CAST, HISTOGRAM
    flags: Vp_Flags;                  // VPIRFlags (VPRecipeWithIRFlags, WIDEN_INT_OR_FP_INDUCTION, REDUCTION_PHI)
    md: [..] Vp_Md;                   // VPIRMetadata
    name: string;                     // INSTRUCTION, WIDEN_PHI
    with_type: bool;                  // INSTRUCTION: created as VPInstructionWithType (casts, loads, WideIVStep, ...)
    ir_inst: Value_Id = NONE;         // IR_INSTRUCTION: the wrapped instruction; WIDEN_*LOAD/STORE*: the ingredient;
                                      // WIDEN_INT_OR_FP_INDUCTION: the TruncInst (or NONE); INTERLEAVE: insert position
    iid: Intrinsic_Id;                // WIDEN_INTRINSIC, WIDEN_MEM_INTRINSIC
    may_read: bool; may_write: bool; may_side_effects: bool;   // WIDEN_INTRINSIC
    src_elt_ty: Type_Id = NONE;       // WIDEN_GEP, VECTOR_POINTER, VECTOR_END_POINTER
    stride: s64;                      // VECTOR_END_POINTER
    ind: s32 = -1;                    // WIDEN_*INDUCTION: index into vpl.inds (InductionDescriptor copies)
    ind_kind: Ind_Kind;               // DERIVED_IV
    fp_binop: Value_Id = NONE;        // DERIVED_IV
    ind_opcode: Opcode;               // SCALAR_IV_STEPS (InductionOpcode)
    rdx_kind: Recur_Kind;             // REDUCTION_PHI, REDUCTION
    rdx_style: Vp_Rdx_Style;          // REDUCTION_PHI, REDUCTION
    rdx_scale: u32 = 1;               // RdxUnordered::VFScaleFactor
    has_uses_outside_chain: bool;     // REDUCTION_PHI
    is_conditional: bool;             // REDUCTION
    single_scalar: bool;              // REPLICATE
    predicated: bool;                 // REPLICATE
    align: u64;                       // WIDEN_*LOAD/STORE*, WIDEN_MEM_INTRINSIC
    consecutive: bool;                // WIDEN_*LOAD/STORE*
    masked: bool;                     // WIDEN_*LOAD/STORE*, INTERLEAVE (HasMask)
    needs_mask_for_gaps: bool;        // INTERLEAVE
    ig: s32 = -1;                     // INTERLEAVE: interleave group index
    expr: Scev_Id;                    // EXPAND_SCEV
    variant: Value_Id = NONE;         // WIDEN_CALL: the vector function
    expr_type: u8;                    // EXPRESSION: ExpressionTypes
    expr_recipes: [..] Vp_Rec;        // EXPRESSION (unlinked member recipes, possibly with duplicates)
    expr_placeholders: [..] Vp_Val;   // EXPRESSION: LiveInPlaceholders (symbolic values), one per operand
    dead: bool;
}
Vp_Rdx_Style :: enum u8 { UNORDERED; IN_LOOP; ORDERED; }
Vp_Md :: struct { kind: u32; node: Md_Id; }

Vp_Plan :: struct {
    blocks: [..] Vp_Block_Row;
    values: [..] Vp_Value_Row;
    recipes: [..] Vp_Recipe_Row;
    inds: [..] Ind_Desc;                     // induction descriptors referenced by recipes
    entry: Vp_Blk = NONE;
    scalar_header: Vp_Blk = NONE;
    exit_blocks: [..] Vp_Blk;
    vfs: [..] Ec;                            // SmallSetVector<ElementCount>
    ufs: [..] u32;
    name: string;
    trip_count: Vp_Val = NONE;
    btc: Vp_Val = NONE;                      // BackedgeTakenCount (symbolic)
    vector_trip_count: Vp_Val = NONE;
    vf: Vp_Val = NONE;
    uf: Vp_Val = NONE;
    vfxuf: Vp_Val = NONE;
    live_ins: Table(Value_Id, Vp_Val);       // SmallMapVector<Value *, VPIRValue *>
    live_in_order: [..] Value_Id;
    created_blocks: [..] Vp_Blk;
}

vpl: *Vp_Plan;
vp_use :: (p: *Vp_Plan) { vpl = p; }

vb :: inline (b: Vp_Blk) -> *Vp_Block_Row { return *vpl.blocks[b]; }
vv :: inline (v: Vp_Val) -> *Vp_Value_Row { return *vpl.values[v]; }
vr :: inline (r: Vp_Rec) -> *Vp_Recipe_Row { return *vpl.recipes[r]; }

// ---------------------------------------------------------------- values

vp_new_value :: (kind: Vp_Value_Kind, ty: Type_Id, uv: Value_Id = NONE) -> Vp_Val {
    row: Vp_Value_Row;
    row.kind = kind; row.ty = ty; row.uv = uv;
    row.users.allocator = temp;
    array_add(*vpl.values, row);
    return cast(Vp_Val) (vpl.values.count - 1);
}
vp_new_symbolic :: (ty: Type_Id) -> Vp_Val { return vp_new_value(.SYMBOLIC, ty); }

// VPlan::getOrAddLiveIn
vp_live_in :: (v: Value_Id) -> Vp_Val {
    found, x := table_find(*vpl.live_ins, v);
    if found return x;
    nv := vp_new_value(.IR, vtype(v), v);
    table_set(*vpl.live_ins, v, nv);
    array_add(*vpl.live_in_order, v);
    return nv;
}
vp_get_live_in :: (v: Value_Id) -> Vp_Val { found, x := table_find(*vpl.live_ins, v); return ifx found then x else NONE; }
vp_const_int :: (ty: Type_Id, val: u64) -> Vp_Val { return vp_live_in(const_int(ty, val)); }
vp_const_int_ap :: (a: APInt) -> Vp_Val { return vp_live_in(const_int_ap(type_int(a.bits), a)); }
vp_true :: () -> Vp_Val { return vp_const_int(type_int(1), 1); }
vp_false :: () -> Vp_Val { return vp_const_int(type_int(1), 0); }
vp_zero :: (ty: Type_Id) -> Vp_Val { return vp_const_int(ty, 0); }
vp_poison :: (ty: Type_Id) -> Vp_Val { return vp_live_in(const_poison(ty)); }

vp_is_ir_value :: inline (v: Vp_Val) -> bool { return vv(v).kind == .IR; }
vp_is_symbolic :: inline (v: Vp_Val) -> bool { k := vv(v).kind; return k == .SYMBOLIC || k == .REGION; }
vp_is_region_value :: inline (v: Vp_Val) -> bool { return vv(v).kind == .REGION; }
vp_ir :: inline (v: Vp_Val) -> Value_Id { return vv(v).uv; }   // getLiveInIRValue
vp_uv :: inline (v: Vp_Val) -> Value_Id { return vv(v).uv; }   // getUnderlyingValue
vp_is_constant :: (v: Vp_Val) -> bool { return vp_is_ir_value(v) && is_const(vp_ir(v)); }        // VPConstant
vp_is_constant_int :: (v: Vp_Val) -> bool { return vp_is_ir_value(v) && vkind(vp_ir(v)) == .C_INT; }   // VPConstantInt
vp_const_int_value :: (v: Vp_Val) -> APInt { return const_ap(vp_ir(v)); }
vp_is_const_int_zero :: (v: Vp_Val) -> bool { return vp_is_constant_int(v) && ap_is_zero(vp_const_int_value(v)); }
vp_is_const_int_one :: (v: Vp_Val) -> bool { return vp_is_constant_int(v) && ap_is_one(vp_const_int_value(v)); }

// VPValue::getScalarType
vp_scalar_type :: (v: Vp_Val) -> Type_Id {
    row := vv(v);
    if row.kind == .IR return vtype(row.uv);
    return row.ty;
}
// VPValue::getDefiningRecipe
vp_def :: inline (v: Vp_Val) -> Vp_Rec {
    if v == NONE return NONE;
    k := vv(v).kind;
    if k == .SINGLE_DEF || k == .MULTI_DEF return vv(v).def;
    return NONE;
}
vp_num_users :: inline (v: Vp_Val) -> s64 { return vv(v).users.count; }
vp_has_one_use :: inline (v: Vp_Val) -> bool { return vv(v).users.count == 1; }
vp_single_user :: (v: Vp_Val) -> Vp_Rec { if vv(v).users.count == 1 return vv(v).users[0]; return NONE; }
// hasMoreThanOneUniqueUser
vp_has_more_than_one_unique_user :: (v: Vp_Val) -> bool {
    u := vv(v).users;
    if u.count == 0 return false;
    k := 1;
    while k < u.count && u[0] == u[k] k += 1;
    return k != u.count;
}
vp_users_snapshot :: (v: Vp_Val) -> [..] Vp_Rec {   // make_early_inc_range(V->users())
    out: [..] Vp_Rec; out.allocator = temp;
    for vv(v).users array_add(*out, it);
    return out;
}
vp_add_user :: (v: Vp_Val, r: Vp_Rec) { array_add(*vv(v).users, r); }
vp_remove_user :: (v: Vp_Val, r: Vp_Rec) {
    u := *vv(v).users;
    for k: 0..u.count-1 if u.*[k] == r { array_ordered_remove_by_index(u, k); return; }
}

// VPValue::replaceUsesWithIf: `pred(r, idx)` decides per use
vp_replace_uses_with_if :: (old: Vp_Val, new: Vp_Val, pred: (r: Vp_Rec, idx: s64, data: *void) -> bool, data: *void) {
    if old == new return;
    j := 0;
    while j < vv(old).users.count {
        r := vv(old).users[j];
        removed := false;
        for i: 0..vr(r).ops.count-1 {
            if vr(r).ops[i] != old || !pred(r, i, data) continue;
            removed = true;
            vp_set_operand(r, i, new);
        }
        if !removed j += 1;
    }
}
// VPValue::replaceAllUsesWith
vp_rauw :: (old: Vp_Val, new: Vp_Val) {
    always :: (r: Vp_Rec, idx: s64, data: *void) -> bool { return true; }
    vp_replace_uses_with_if(old, new, always, null);
    if vp_is_symbolic(old) vv(old).materialized = true;
}
// VPUser::replaceUsesOfWith
vp_replace_uses_of_with :: (r: Vp_Rec, from: Vp_Val, to: Vp_Val) {
    for i: 0..vr(r).ops.count-1 if vr(r).ops[i] == from vp_set_operand(r, i, to);
}

// ---------------------------------------------------------------- recipes (VPUser / VPDef)

vp_op :: inline (r: Vp_Rec, i: s64) -> Vp_Val { return vr(r).ops[i]; }
vp_nops :: inline (r: Vp_Rec) -> s64 { return vr(r).ops.count; }
vp_add_operand :: (r: Vp_Rec, v: Vp_Val) { array_add(*vr(r).ops, v); vp_add_user(v, r); }
vp_set_operand :: (r: Vp_Rec, i: s64, v: Vp_Val) {
    old := vr(r).ops[i];
    vp_remove_user(old, r);
    vr(r).ops[i] = v;
    vp_add_user(v, r);
}
vp_remove_operand :: (r: Vp_Rec, i: s64) {
    vp_remove_user(vr(r).ops[i], r);
    array_ordered_remove_by_index(*vr(r).ops, i);
}
vp_swap_operands :: (r: Vp_Rec) { o := *vr(r).ops; t := o.*[0]; o.*[0] = o.*[1]; o.*[1] = t; }
vp_single_value :: inline (r: Vp_Rec) -> Vp_Val { return vr(r).def; }   // getVPSingleValue
vp_num_defined_values :: (r: Vp_Rec) -> s64 { if vr(r).def != NONE return 1; return vr(r).defs.count; }
vp_defined_value :: (r: Vp_Rec, i: s64) -> Vp_Val { if vr(r).def != NONE return vr(r).def; return vr(r).defs[i]; }

vp_new_recipe :: (kind: Vp_Kind, ops: [] Vp_Val, dl: Md_Id = NONE) -> Vp_Rec {
    row: Vp_Recipe_Row;
    row.kind = kind; row.dl = dl;
    row.ops.allocator = temp; row.defs.allocator = temp; row.md.allocator = temp; row.expr_recipes.allocator = temp; row.expr_placeholders.allocator = temp;
    array_add(*vpl.recipes, row);
    r := cast(Vp_Rec) (vpl.recipes.count - 1);
    for ops vp_add_operand(r, it);
    return r;
}
// VPSingleDefRecipe: the recipe and its VPSingleDefValue
vp_new_single_def :: (kind: Vp_Kind, ops: [] Vp_Val, ty: Type_Id, uv: Value_Id = NONE, dl: Md_Id = NONE) -> Vp_Rec {
    r := vp_new_recipe(kind, ops, dl);
    v := vp_new_value(.SINGLE_DEF, ty, uv);
    vv(v).def = r;
    vr(r).def = v;
    return r;
}
vp_add_multi_def_value :: (r: Vp_Rec, uv: Value_Id, ty: Type_Id) -> Vp_Val {
    v := vp_new_value(.MULTI_DEF, ty, uv);
    vv(v).def = r;
    array_add(*vr(r).defs, v);
    return v;
}
vp_set_underlying :: (v: Vp_Val, uv: Value_Id) { vv(v).uv = uv; }
vp_underlying_instr :: (r: Vp_Rec) -> Value_Id { return vv(vr(r).def).uv; }   // VPSingleDefRecipe::getUnderlyingInstr

vp_is_single_def_kind :: (k: Vp_Kind) -> bool {
    return !(k == .BRANCH_ON_MASK || k == .INTERLEAVE_EVL || k == .INTERLEAVE || k == .IR_INSTRUCTION ||
             k == .WIDEN_STORE_EVL || k == .WIDEN_STORE || k == .HISTOGRAM);
}
vp_is_phi_kind :: (k: Vp_Kind) -> bool { return k >= VP_FIRST_PHI && k <= VP_LAST_PHI; }
vp_is_header_phi_kind :: (k: Vp_Kind) -> bool { return k >= VP_FIRST_HEADER_PHI && k <= VP_LAST_HEADER_PHI; }
vp_is_header_phi :: (r: Vp_Rec) -> bool { return r != NONE && vp_is_header_phi_kind(vr(r).kind); }
vp_is_with_ir_flags_kind :: (k: Vp_Kind) -> bool {
    if k == {
        case .BLEND; #through; case .INSTRUCTION; #through; case .WIDEN; #through; case .WIDEN_GEP; #through;
        case .WIDEN_CALL; #through; case .WIDEN_CAST; #through; case .WIDEN_INTRINSIC; #through;
        case .WIDEN_MEM_INTRINSIC; #through; case .REDUCTION; #through; case .REDUCTION_EVL; #through;
        case .REPLICATE; #through; case .VECTOR_END_POINTER; #through; case .VECTOR_POINTER; #through;
        case .WIDEN_CANONICAL_IV; return true;
    }
    return false;
}
vp_is_widen_memory_kind :: (k: Vp_Kind) -> bool { return k == .WIDEN_LOAD || k == .WIDEN_LOAD_EVL || k == .WIDEN_STORE || k == .WIDEN_STORE_EVL; }
vp_is_widen_induction_kind :: (k: Vp_Kind) -> bool { return k == .WIDEN_INT_OR_FP_INDUCTION || k == .WIDEN_POINTER_INDUCTION; }

// isa<VPInstruction>(V) with an opcode
vp_is_vpi :: (r: Vp_Rec, opc: u16) -> bool { return r != NONE && vr(r).kind == .INSTRUCTION && vr(r).opcode == opc; }
vp_val_is_vpi :: (v: Vp_Val, opc: u16) -> bool { return vp_is_vpi(vp_def(v), opc); }
// VPPhi (VPInstruction with opcode PHI)
vp_is_vp_phi :: (r: Vp_Rec) -> bool { return vp_is_vpi(r, vp_opc(.PHI)); }
// VPIRPhi
vp_is_ir_phi :: (r: Vp_Rec) -> bool { return r != NONE && vr(r).kind == .IR_INSTRUCTION && is_phi(vr(r).ir_inst); }
// VPRecipeBase::isPhi
vp_is_phi_recipe :: (r: Vp_Rec) -> bool { return vp_is_phi_kind(vr(r).kind) || vp_is_vp_phi(r) || vp_is_ir_phi(r); }
// VPInstructionWithType::classof
vp_is_instruction_with_type :: (r: Vp_Rec) -> bool {
    if r == NONE || vr(r).kind != .INSTRUCTION return false;
    o := vr(r).opcode;
    if vp_opcode_is_cast(o) return true;
    return o == VPI_WIDE_IV_STEP || o == VPI_STEP_VECTOR || o == VPI_INTRINSIC || o == vp_opc(.LOAD);
}

// ---------------------------------------------------------------- recipe lists (iplist<VPRecipeBase>)

vp_insert_recipe :: (r: Vp_Rec, b: Vp_Blk, before: Vp_Rec) {   // VPBasicBlock::insert(Recipe, InsertPt); NONE = end()
    assert(vr(r).parent == NONE, "recipe already in VPlan");
    vr(r).parent = b;
    if before == NONE {
        vr(r).prev = vb(b).last; vr(r).next = NONE;
        if vb(b).last != NONE vr(vb(b).last).next = r; else vb(b).first = r;
        vb(b).last = r;
    } else {
        p := vr(before).prev;
        vr(r).prev = p; vr(r).next = before;
        vr(before).prev = r;
        if p != NONE vr(p).next = r; else vb(b).first = r;
    }
}
vp_append_recipe :: (b: Vp_Blk, r: Vp_Rec) { vp_insert_recipe(r, b, NONE); }
vp_insert_before :: (r: Vp_Rec, pos: Vp_Rec) { vp_insert_recipe(r, vr(pos).parent, pos); }
vp_insert_after :: (r: Vp_Rec, pos: Vp_Rec) { vp_insert_recipe(r, vr(pos).parent, vr(pos).next); }
vp_remove_from_parent :: (r: Vp_Rec) {
    b := vr(r).parent;
    p := vr(r).prev; n := vr(r).next;
    if p != NONE vr(p).next = n; else vb(b).first = n;
    if n != NONE vr(n).prev = p; else vb(b).last = p;
    vr(r).parent = NONE; vr(r).prev = NONE; vr(r).next = NONE;
}
vp_move_before :: (r: Vp_Rec, b: Vp_Blk, before: Vp_Rec) { vp_remove_from_parent(r); vp_insert_recipe(r, b, before); }
vp_move_after :: (r: Vp_Rec, pos: Vp_Rec) { vp_remove_from_parent(r); vp_insert_after(r, pos); }
// VPRecipeBase::eraseFromParent: unlink and delete (operands dropped, defined values deleted)
vp_erase_recipe :: (r: Vp_Rec) {
    if vr(r).parent != NONE vp_remove_from_parent(r);
    vp_delete_recipe(r);
}
vp_delete_recipe :: (r: Vp_Rec) {
    for vr(r).ops vp_remove_user(it, r);
    vr(r).ops.count = 0;
    if vr(r).def != NONE {
        assert(vv(vr(r).def).users.count == 0, "deleting a VPValue with remaining users");
        vv(vr(r).def).def = NONE;
    }
    for vr(r).defs vv(it).def = NONE;
    vr(r).dead = true;
}
vp_block_recipes :: (b: Vp_Blk) -> [..] Vp_Rec {   // a snapshot (make_early_inc_range safe)
    out: [..] Vp_Rec; out.allocator = temp;
    r := vb(b).first;
    while r != NONE { array_add(*out, r); r = vr(r).next; }
    return out;
}
vp_block_empty :: (b: Vp_Blk) -> bool { return vb(b).first == NONE; }
// VPBasicBlock::getFirstNonPhi (NONE = end())
vp_first_non_phi :: (b: Vp_Blk) -> Vp_Rec {
    r := vb(b).first;
    while r != NONE && vp_is_phi_recipe(r) r = vr(r).next;
    return r;
}
vp_block_phis :: (b: Vp_Blk) -> [..] Vp_Rec {
    out: [..] Vp_Rec; out.allocator = temp;
    r := vb(b).first;
    while r != NONE && vp_is_phi_recipe(r) { array_add(*out, r); r = vr(r).next; }
    return out;
}

// ---------------------------------------------------------------- blocks

vp_new_block :: (kind: Vp_Block_Kind, name: string) -> Vp_Blk {
    row: Vp_Block_Row;
    row.kind = kind; row.name = name;
    row.preds.allocator = temp; row.succs.allocator = temp;
    array_add(*vpl.blocks, row);
    b := cast(Vp_Blk) (vpl.blocks.count - 1);
    array_add(*vpl.created_blocks, b);
    return b;
}
// VPlan::createVPBasicBlock
vp_create_basic_block :: (name: string, r: Vp_Rec = NONE) -> Vp_Blk {
    b := vp_new_block(.BASIC, name);
    if r != NONE vp_append_recipe(b, r);
    return b;
}
// VPlan::createEmptyVPIRBasicBlock
vp_create_empty_ir_basic_block :: (irbb: Value_Id) -> Vp_Blk {
    b := vp_new_block(.IR_BASIC, tconcat("ir-bb<", ir.v_name[irbb], ">"));
    vb(b).irbb = irbb;
    return b;
}
// VPlan::createVPIRBasicBlock: a VPIRInstruction for every instruction but the terminator
vp_create_ir_basic_block :: (irbb: Value_Id) -> Vp_Blk {
    b := vp_create_empty_ir_basic_block(irbb);
    t := block_terminator(irbb);
    for i: block_insts(irbb) {
        if i == t break;
        vp_append_recipe(b, vp_new_ir_instruction(i));
    }
    return b;
}
// VPIRInstruction::create
vp_new_ir_instruction :: (i: Value_Id) -> Vp_Rec {
    r := vp_new_recipe(.IR_INSTRUCTION, .[]);
    vr(r).ir_inst = i;
    return r;
}
// VPlan::createLoopRegion
vp_create_loop_region :: (can_iv_ty: Type_Id, dl: Md_Id, name := "", entry: Vp_Blk = NONE, exiting: Vp_Blk = NONE) -> Vp_Blk {
    b := vp_new_block(.REGION, name);
    vp_region_init(b, entry, exiting);
    cv := vp_new_value(.REGION, can_iv_ty);
    vv(cv).region = b; vv(cv).dl = dl;
    vb(b).can_iv = cv;
    return b;
}
// VPlan::createReplicateRegion
vp_create_replicate_region :: (entry: Vp_Blk, exiting: Vp_Blk, name := "") -> Vp_Blk {
    b := vp_new_block(.REGION, name);
    vp_region_init(b, entry, exiting);
    return b;
}
vp_region_init :: (b: Vp_Blk, entry: Vp_Blk, exiting: Vp_Blk) {
    vb(b).entry = entry; vb(b).exiting = exiting;
    if entry != NONE { vb(entry).parent = b; vb(exiting).parent = b; }
}
vp_create_header_mask :: (region: Vp_Blk) -> Vp_Val {
    cv := vb(region).can_iv;
    m := vp_new_value(.REGION, type_int(1));
    vv(m).region = vv(cv).region;
    vb(region).header_mask = m;
    return m;
}
vp_is_region :: inline (b: Vp_Blk) -> bool { return b != NONE && vb(b).kind == .REGION; }
vp_is_basic :: inline (b: Vp_Blk) -> bool { return b != NONE && vb(b).kind != .REGION; }     // isa<VPBasicBlock>
vp_is_ir_basic :: inline (b: Vp_Blk) -> bool { return b != NONE && vb(b).kind == .IR_BASIC; }
vp_is_replicator :: inline (b: Vp_Blk) -> bool { return vb(b).can_iv == NONE; }
vp_region_set_entry :: (r: Vp_Blk, e: Vp_Blk) { vb(r).entry = e; vb(e).parent = r; }
vp_region_set_exiting :: (r: Vp_Blk, e: Vp_Blk) { vb(r).exiting = e; vb(e).parent = r; }
vp_single_succ :: (b: Vp_Blk) -> Vp_Blk { if vb(b).succs.count == 1 return vb(b).succs[0]; return NONE; }
vp_single_pred :: (b: Vp_Blk) -> Vp_Blk { if vb(b).preds.count == 1 return vb(b).preds[0]; return NONE; }
vp_num_succs :: inline (b: Vp_Blk) -> s64 { return vb(b).succs.count; }
vp_num_preds :: inline (b: Vp_Blk) -> s64 { return vb(b).preds.count; }
vp_swap_succs :: (b: Vp_Blk) { s := *vb(b).succs; t := s.*[0]; s.*[0] = s.*[1]; s.*[1] = t; }
vp_swap_preds :: (b: Vp_Blk) { s := *vb(b).preds; t := s.*[0]; s.*[0] = s.*[1]; s.*[1] = t; }
vp_index_of :: (list: [] Vp_Blk, b: Vp_Blk) -> s64 { for list if it == b return it_index; return -1; }
vp_contains_blk :: (list: [] Vp_Blk, b: Vp_Blk) -> bool { return vp_index_of(list, b) >= 0; }
vp_remove_succ :: (b: Vp_Blk, s: Vp_Blk) { i := vp_index_of(vb(b).succs, s); assert(i >= 0); array_ordered_remove_by_index(*vb(b).succs, i); }
vp_remove_pred :: (b: Vp_Blk, p: Vp_Blk) { i := vp_index_of(vb(b).preds, p); assert(i >= 0); array_ordered_remove_by_index(*vb(b).preds, i); }
vp_replace_pred :: (b: Vp_Blk, old: Vp_Blk, new: Vp_Blk) { i := vp_index_of(vb(b).preds, old); assert(i >= 0); vb(b).preds[i] = new; }
vp_replace_succ :: (b: Vp_Blk, old: Vp_Blk, new: Vp_Blk) { i := vp_index_of(vb(b).succs, old); assert(i >= 0); vb(b).succs[i] = new; }

// getEntryBasicBlock / getExitingBasicBlock
vp_entry_basic_block :: (b_in: Vp_Blk) -> Vp_Blk { b := b_in; while vp_is_region(b) b = vb(b).entry; return b; }
vp_exiting_basic_block :: (b_in: Vp_Blk) -> Vp_Blk { b := b_in; while vp_is_region(b) b = vb(b).exiting; return b; }
// getEnclosingBlockWithSuccessors / ...Predecessors
vp_enclosing_block_with_succs :: (b: Vp_Blk) -> Vp_Blk {
    if vb(b).succs.count || vb(b).parent == NONE return b;
    return vp_enclosing_block_with_succs(vb(b).parent);
}
vp_enclosing_block_with_preds :: (b: Vp_Blk) -> Vp_Blk {
    if vb(b).preds.count || vb(b).parent == NONE return b;
    return vp_enclosing_block_with_preds(vb(b).parent);
}
vp_single_hierarchical_pred :: (b: Vp_Blk) -> Vp_Blk { return vp_single_pred(vp_enclosing_block_with_preds(b)); }
// VPBasicBlock::getEnclosingLoopRegion
vp_enclosing_loop_region :: (b: Vp_Blk) -> Vp_Blk {
    p := vb(b).parent;
    if p != NONE && vp_is_replicator(p) p = vb(p).parent;
    return p;
}
// VPRecipeBase::getRegion
vp_recipe_region :: (r: Vp_Rec) -> Vp_Blk { return vb(vr(r).parent).parent; }
vp_is_exiting :: (b: Vp_Blk) -> bool { p := vb(b).parent; return p != NONE && vp_exiting_basic_block(p) == b; }

// hasConditionalTerminator / getTerminator
vp_terminator :: (b: Vp_Blk) -> Vp_Rec {
    if vp_block_empty(b) return NONE;
    if vb(b).succs.count >= 2 || (vp_is_exiting(b) && !vp_is_replicator(vb(b).parent)) return vb(b).last;
    return NONE;
}
// VPBasicBlock::getCFGPredecessor
vp_cfg_predecessor :: (b: Vp_Blk, idx: s64) -> Vp_Blk {
    pred: Vp_Blk;
    if vb(b).preds.count pred = vb(b).preds[idx];
    else {
        region := vb(b).parent;
        pred = ifx idx == 0 then vp_single_pred(region) else region;
    }
    return vp_exiting_basic_block(pred);
}

// ---------------------------------------------------------------- VPBlockUtils

vpbu_connect :: (from: Vp_Blk, to: Vp_Blk, pred_idx: s64 = -1, succ_idx: s64 = -1) {
    if succ_idx == -1 array_add(*vb(from).succs, to); else vb(from).succs[succ_idx] = to;
    if pred_idx == -1 array_add(*vb(to).preds, from); else vb(to).preds[pred_idx] = from;
}
vpbu_disconnect :: (from: Vp_Blk, to: Vp_Blk) { vp_remove_succ(from, to); vp_remove_pred(to, from); }
vpbu_transfer_successors :: (old: Vp_Blk, new: Vp_Blk) {
    for s: vb(old).succs vp_replace_pred(s, old, new);
    assert(vb(new).succs.count == 0, "successors already set");
    for s: vb(old).succs array_add(*vb(new).succs, s);
    vb(old).succs.count = 0;
}
vpbu_insert_block_after :: (new: Vp_Blk, ptr: Vp_Blk) {
    vb(new).parent = vb(ptr).parent;
    vpbu_transfer_successors(ptr, new);
    vpbu_connect(ptr, new);
}
vpbu_insert_block_before :: (new: Vp_Blk, ptr: Vp_Blk) {
    vb(new).parent = vb(ptr).parent;
    preds: [..] Vp_Blk; preds.allocator = temp;
    for vb(ptr).preds array_add(*preds, it);
    for p: preds { vp_replace_succ(p, ptr, new); array_add(*vb(new).preds, p); }
    vb(ptr).preds.count = 0;
    vpbu_connect(new, ptr);
}
vpbu_insert_two_blocks_after :: (if_true: Vp_Blk, if_false: Vp_Blk, ptr: Vp_Blk) {
    array_add(*vb(ptr).succs, if_true); array_add(*vb(ptr).succs, if_false);
    array_add(*vb(if_true).preds, ptr); array_add(*vb(if_false).preds, ptr);
    vb(if_true).parent = vb(ptr).parent; vb(if_false).parent = vb(ptr).parent;
}
vpbu_reassociate_blocks :: (old: Vp_Blk, new: Vp_Blk) {
    preds: [..] Vp_Blk; preds.allocator = temp; for vb(old).preds array_add(*preds, it);
    succs: [..] Vp_Blk; succs.allocator = temp; for vb(old).succs array_add(*succs, it);
    for preds vp_replace_succ(it, old, new);
    for succs vp_replace_pred(it, old, new);
    for preds array_add(*vb(new).preds, it);
    for succs array_add(*vb(new).succs, it);
    vb(old).preds.count = 0; vb(old).succs.count = 0;
}
vpbu_insert_on_edge :: (from: Vp_Blk, to: Vp_Blk, ptr: Vp_Blk) {
    si := vp_index_of(vb(from).succs, to);
    pi := vp_index_of(vb(to).preds, from);
    vpbu_connect(from, ptr, -1, si);
    vpbu_connect(ptr, to, pi, -1);
}

// ---------------------------------------------------------------- traversals (VPlanCFG.h)

// children of `b` in the hierarchical ("deep") graph: a region's child is its entry; a block without successors
// continues with the successors of its innermost enclosing block that has some
vp_deep_children :: (b: Vp_Blk, out: *[..] Vp_Blk) {
    out.count = 0;
    if vp_is_region(b) { array_add(out, vb(b).entry); return; }
    c := b;
    while c != NONE && vb(c).succs.count == 0 c = vb(c).parent;
    if c == NONE return;
    for vb(c).succs array_add(out, it);
}
vp_shallow_children :: (b: Vp_Blk, out: *[..] Vp_Blk) { out.count = 0; for vb(b).succs array_add(out, it); }

// depth_first (df_iterator, preorder) over the deep or shallow graph
vp_depth_first :: (start: Vp_Blk, deep: bool) -> [..] Vp_Blk {
    out: [..] Vp_Blk; out.allocator = temp;
    visited: Table(Vp_Blk, bool); visited.allocator = temp;
    Frame :: struct { b: Vp_Blk; k: s64; kids: [..] Vp_Blk; }
    stack: [..] Frame; stack.allocator = temp;
    push :: (stack: *[..] Frame, b: Vp_Blk, deep: bool) {
        f: Frame; f.b = b; f.k = 0; f.kids.allocator = temp;
        if deep vp_deep_children(b, *f.kids); else vp_shallow_children(b, *f.kids);
        array_add(stack, f);
    }
    table_set(*visited, start, true);
    array_add(*out, start);
    push(*stack, start, deep);
    while stack.count {
        top := *stack[stack.count - 1];
        if top.k >= top.kids.count { stack.count -= 1; continue; }
        c := top.kids[top.k];
        top.k += 1;
        if table_contains(*visited, c) continue;
        table_set(*visited, c, true);
        array_add(*out, c);
        push(*stack, c, deep);
    }
    return out;
}
vp_depth_first_shallow :: (b: Vp_Blk) -> [..] Vp_Blk { return vp_depth_first(b, false); }
vp_depth_first_deep :: (b: Vp_Blk) -> [..] Vp_Blk { return vp_depth_first(b, true); }

// ReversePostOrderTraversal over the deep or shallow graph (po_iterator: post order of a DFS with children in order)
vp_rpo :: (start: Vp_Blk, deep: bool) -> [..] Vp_Blk {
    post: [..] Vp_Blk; post.allocator = temp;
    visited: Table(Vp_Blk, bool); visited.allocator = temp;
    Frame :: struct { b: Vp_Blk; k: s64; kids: [..] Vp_Blk; }
    stack: [..] Frame; stack.allocator = temp;
    push :: (stack: *[..] Frame, b: Vp_Blk, deep: bool) {
        f: Frame; f.b = b; f.k = 0; f.kids.allocator = temp;
        if deep vp_deep_children(b, *f.kids); else vp_shallow_children(b, *f.kids);
        array_add(stack, f);
    }
    table_set(*visited, start, true);
    push(*stack, start, deep);
    while stack.count {
        top := *stack[stack.count - 1];
        if top.k >= top.kids.count { array_add(*post, top.b); stack.count -= 1; continue; }
        c := top.kids[top.k];
        top.k += 1;
        if table_contains(*visited, c) continue;
        table_set(*visited, c, true);
        push(*stack, c, deep);
    }
    out: [..] Vp_Blk; out.allocator = temp;
    for < post array_add(*out, it);
    return out;
}
vp_blocks_only_basic :: (list: [] Vp_Blk) -> [..] Vp_Blk {   // VPBlockUtils::blocksOnly<VPBasicBlock>
    out: [..] Vp_Blk; out.allocator = temp;
    for list if vp_is_basic(it) array_add(*out, it);
    return out;
}
vp_blocks_only_region :: (list: [] Vp_Blk) -> [..] Vp_Blk {
    out: [..] Vp_Blk; out.allocator = temp;
    for list if vp_is_region(it) array_add(*out, it);
    return out;
}
// all VPBasicBlocks in deep depth-first order from the plan entry
vp_all_basic_blocks_deep :: () -> [..] Vp_Blk { return vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)); }

// ---------------------------------------------------------------- VPlan accessors

// VPlan::getVectorLoopRegion: the first region in a shallow depth-first walk from the entry
vp_vector_loop_region :: () -> Vp_Blk {
    for vp_depth_first_shallow(vpl.entry) if vp_is_region(it) return it;
    return NONE;
}
vp_vector_preheader :: () -> Vp_Blk { r := vp_vector_loop_region(); if r == NONE return NONE; return vp_single_pred(r); }
vp_middle_block :: () -> Vp_Blk { r := vp_vector_loop_region(); s := vb(r).succs; return s[s.count - 1]; }
vp_scalar_preheader :: () -> Vp_Blk {
    p := vp_single_pred(vpl.scalar_header);
    if p == NONE || !vp_is_basic(p) return NONE;
    return p;
}
vp_is_exit_block :: (b: Vp_Blk) -> bool { return vp_contains_blk(vpl.exit_blocks, b); }
vp_has_vf :: (vf: Ec) -> bool { for vpl.vfs if ec_eq(it, vf) return true; return false; }
vp_add_vf :: (vf: Ec) { if !vp_has_vf(vf) array_add(*vpl.vfs, vf); }
vp_set_vf :: (vf: Ec) { vpl.vfs.count = 0; array_add(*vpl.vfs, vf); }
vp_single_vf :: () -> Ec { assert(vpl.vfs.count == 1); return vpl.vfs[0]; }
vp_has_scalar_vf_only :: () -> bool { return vpl.vfs.count == 1 && ec_is_scalar(vpl.vfs[0]); }
vp_has_uf :: (uf: u32) -> bool { if vpl.ufs.count == 0 return true; return array_find(vpl.ufs, uf); }
vp_set_uf :: (uf: u32) { vpl.ufs.count = 0; array_add(*vpl.ufs, uf); }
vp_is_unrolled :: () -> bool { return vpl.ufs.count == 1; }
vp_index_type :: () -> Type_Id { return vv(vpl.vf).ty; }
vp_or_create_backedge_taken_count :: () -> Vp_Val {
    if vpl.btc == NONE vpl.btc = vp_new_symbolic(vv(vpl.vector_trip_count).ty);
    return vpl.btc;
}
// VPlan::hasEarlyExit
vp_has_early_exit :: () -> bool {
    n := 0;
    for vpl.exit_blocks n += vb(it).preds.count;
    sph := vp_scalar_preheader();
    sphp := ifx sph != NONE then vp_single_pred(sph) else NONE;
    if sphp != NONE && vb(sphp).succs.count == 1 return n >= 1;
    return n > 1;
}
// VPlan::hasScalarTail
vp_has_scalar_tail :: () -> bool {
    sph := vp_scalar_preheader();
    return sph != NONE && vp_contains_blk(vb(sph).preds, vp_middle_block());
}
vp_has_tail_folded :: () -> bool { r := vp_vector_loop_region(); return r != NONE && vb(r).header_mask != NONE; }

// VPlan::VPlan(Loop *L, Type *IdxTy)
vp_plan_new :: (li: *Loop_Info, l: Loop_Id, idx_ty: Type_Id) -> *Vp_Plan {
    p := New(Vp_Plan,, allocator = temp);
    p.blocks.allocator = temp; p.values.allocator = temp; p.recipes.allocator = temp; p.inds.allocator = temp;
    p.exit_blocks.allocator = temp; p.vfs.allocator = temp; p.ufs.allocator = temp; p.live_ins.allocator = temp;
    p.live_in_order.allocator = temp; p.created_blocks.allocator = temp;
    vp_use(p);
    p.vector_trip_count = vp_new_symbolic(idx_ty);
    p.vf = vp_new_symbolic(idx_ty);
    p.uf = vp_new_symbolic(idx_ty);
    p.vfxuf = vp_new_symbolic(idx_ty);
    p.entry = vp_create_ir_basic_block(li_loop_preheader(li, l));
    p.scalar_header = vp_create_ir_basic_block(li_header(li, l));
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(li, l, *exits);
    for exits array_add(*p.exit_blocks, vp_create_ir_basic_block(it));
    return p;
}

// VPlan::duplicate: the copy keeps every id; user lists are rebuilt in remapOperands' order (deep RPO, recipes,
// operands) and only the recipes reachable from the entry survive, as in LLVM.
vp_duplicate :: (src: *Vp_Plan) -> *Vp_Plan {
    p := New(Vp_Plan,, allocator = temp);
    p.* = src.*;
    copy :: (a: *[..] $T) { b: [..] T; b.allocator = temp; array_reserve(*b, a.count); for a.* array_add(*b, it); a.* = b; }
    copy(*p.blocks); copy(*p.values); copy(*p.recipes); copy(*p.inds); copy(*p.exit_blocks); copy(*p.vfs); copy(*p.ufs);
    copy(*p.live_in_order); copy(*p.created_blocks);
    lt: Table(Value_Id, Vp_Val); lt.allocator = temp;
    for v, k: src.live_ins table_set(*lt, k, v);
    p.live_ins = lt;
    for *p.blocks { copy(*it.preds); copy(*it.succs); }
    for *p.values { copy(*it.users); it.users.count = 0; }
    for *p.recipes { copy(*it.ops); copy(*it.defs); copy(*it.md); copy(*it.expr_recipes); copy(*it.expr_placeholders); }
    vp_use(p);
    reachable: Table(Vp_Rec, bool); reachable.allocator = temp;
    for b: vp_blocks_only_basic(vp_rpo(p.entry, true)) {
        r := vb(b).first;
        while r != NONE {
            table_set(*reachable, r, true);
            if vr(r).kind == .EXPRESSION {
                // the clone's member recipes (cloned and re-internalized by VPExpressionRecipe::clone) only use
                // each other and the placeholders
                seen: [..] Vp_Rec; seen.allocator = temp;
                for x: vr(r).expr_recipes {
                    if array_find(seen, x) continue;
                    array_add(*seen, x);
                    for o: vr(x).ops vp_add_user(o, x);
                }
            }
            for o: vr(r).ops vp_add_user(o, r);
            r = vr(r).next;
        }
    }
    // the clones of unreachable blocks are not made by LLVM: their recipes have no operands in the copy
    for *p.recipes if !it.dead && it.parent != NONE && !table_contains(*reachable, cast(Vp_Rec) it_index) {
        if vb(it.parent).kind == .IR_BASIC && it.parent == p.scalar_header && vb(it.parent).preds.count == 0 continue;
    }
    return p;
}

// ---------------------------------------------------------------- VPDominatorTree (dominance queries only)

Vp_Dom_Tree :: struct {
    order: Table(Vp_Blk, s64);          // RPO number
    idom: Table(Vp_Blk, Vp_Blk);
}
// DominatorTreeBase<VPBlockBase>::recalculate over the hierarchical CFG from the plan entry (Cooper-Harvey-Kennedy;
// only `dominates` is queried, never the tree's child order)
vp_dt_build :: () -> Vp_Dom_Tree {
    t: Vp_Dom_Tree;
    t.order.allocator = temp; t.idom.allocator = temp;
    rpo := vp_rpo(vpl.entry, true);
    for rpo table_set(*t.order, it, it_index);
    preds_of: Table(Vp_Blk, [..] Vp_Blk); preds_of.allocator = temp;
    kids: [..] Vp_Blk; kids.allocator = temp;
    for b: rpo {
        vp_deep_children(b, *kids);
        for c: kids {
            pl := table_find_pointer(*preds_of, c);
            if !pl { e: [..] Vp_Blk; e.allocator = temp; table_set(*preds_of, c, e); pl = table_find_pointer(*preds_of, c); }
            array_add(pl, b);
        }
    }
    table_set(*t.idom, vpl.entry, vpl.entry);
    changed := true;
    while changed {
        changed = false;
        for b: rpo {
            if b == vpl.entry continue;
            pl := table_find_pointer(*preds_of, b);
            if !pl continue;
            new_idom: Vp_Blk = NONE;
            for p: pl.* {
                if !table_contains(*t.idom, p) continue;
                if new_idom == NONE { new_idom = p; continue; }
                a := p; c := new_idom;
                while a != c {
                    _, oa := table_find(*t.order, a); _, oc := table_find(*t.order, c);
                    while oa > oc { _, a = table_find(*t.idom, a); _, oa = table_find(*t.order, a); }
                    while oc > oa { _, c = table_find(*t.idom, c); _, oc = table_find(*t.order, c); }
                }
                new_idom = a;
            }
            found, cur := table_find(*t.idom, b);
            if new_idom != NONE && (!found || cur != new_idom) { table_set(*t.idom, b, new_idom); changed = true; }
        }
    }
    return t;
}
vp_dt_dominates :: (t: *Vp_Dom_Tree, a: Vp_Blk, b: Vp_Blk) -> bool {
    if a == b return true;
    if !table_contains(*t.order, b) return true;    // unreachable blocks are dominated by everything
    if !table_contains(*t.order, a) return false;
    x := b;
    while true {
        _, i := table_find(*t.idom, x);
        if i == x return false;
        if i == a return true;
        x = i;
    }
    return false;
}
vp_dt_properly_dominates_blocks :: (t: *Vp_Dom_Tree, a: Vp_Blk, b: Vp_Blk) -> bool { return a != b && vp_dt_dominates(t, a, b); }
// VPDominatorTree::properlyDominates(const VPRecipeBase *A, const VPRecipeBase *B)
vp_dt_properly_dominates :: (t: *Vp_Dom_Tree, a: Vp_Rec, b: Vp_Rec) -> bool {
    if a == b return false;
    pa := vr(a).parent; pb := vr(b).parent;
    if pa == pb {
        // phis are not reordered relative to each other in LLVM's check: comesBefore in the list
        x := vr(a).next;
        while x != NONE { if x == b return true; x = vr(x).next; }
        return false;
    }
    // a recipe inside a replicate region is treated as its region
    ra := pa; rb := pb;
    if vb(ra).parent != NONE && vp_is_replicator(vb(ra).parent) ra = vb(ra).parent;
    if vb(rb).parent != NONE && vp_is_replicator(vb(rb).parent) rb = vb(rb).parent;
    return vp_dt_dominates(t, ra, rb);
}

// ---------------------------------------------------------------- VPBuilder

Vp_Builder :: struct {
    bb: Vp_Blk = NONE;
    ip: Vp_Rec = NONE;       // insert point; NONE = end of bb
}
vpb_at_end :: (b: Vp_Blk) -> Vp_Builder { return .{b, NONE}; }
vpb_at :: (b: Vp_Blk, ip: Vp_Rec) -> Vp_Builder { return .{b, ip}; }
vpb_before :: (r: Vp_Rec) -> Vp_Builder { return .{vr(r).parent, r}; }
vpb_after :: (r: Vp_Rec) -> Vp_Builder { return .{vr(r).parent, vr(r).next}; }   // VPBuilder::getToInsertAfter
vpb_insert :: (b: *Vp_Builder, r: Vp_Rec) -> Vp_Rec { if b.bb != NONE vp_insert_recipe(r, b.bb, b.ip); return r; }

// VPInstruction constructor
vp_new_instruction :: (opcode: u16, ops: [] Vp_Val, flags := Vp_Flags.{}, md: [] Vp_Md = .[], dl: Md_Id = NONE, name := "", result_ty: Type_Id = NONE) -> Vp_Rec {
    ty := result_ty;
    if ty == NONE ty = vp_compute_scalar_type_for_instruction(opcode, ops);
    r := vp_new_single_def(.INSTRUCTION, ops, ty, NONE, dl);
    vr(r).opcode = opcode; vr(r).flags = flags; vr(r).name = name;
    for md array_add(*vr(r).md, it);
    return r;
}
vpb_nary :: (b: *Vp_Builder, opcode: u16, ops: [] Vp_Val, flags := Vp_Flags.{}, md: [] Vp_Md = .[], dl: Md_Id = NONE, name := "", result_ty: Type_Id = NONE, inst: Value_Id = NONE) -> Vp_Rec {
    r := vp_new_instruction(opcode, ops, flags, md, dl, name, result_ty);
    if inst != NONE vp_set_underlying(vr(r).def, inst);
    return vpb_insert(b, r);
}
vpb_overflowing :: (b: *Vp_Builder, opcode: Opcode, ops: [] Vp_Val, nuw: bool, nsw: bool, dl: Md_Id = NONE, name := "") -> Vp_Rec {
    return vpb_nary(b, vp_opc(opcode), ops, vpf_wrap(nuw, nsw), .[], dl, name);
}
vpb_add :: (b: *Vp_Builder, l: Vp_Val, r: Vp_Val, dl: Md_Id = NONE, name := "", nuw := false, nsw := false) -> Vp_Rec { return vpb_overflowing(b, .ADD, .[l, r], nuw, nsw, dl, name); }
vpb_sub :: (b: *Vp_Builder, l: Vp_Val, r: Vp_Val, dl: Md_Id = NONE, name := "", nuw := false, nsw := false) -> Vp_Rec { return vpb_overflowing(b, .SUB, .[l, r], nuw, nsw, dl, name); }
vpb_not :: (b: *Vp_Builder, v: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, VPI_NOT, .[v], .{}, .[], dl, name); }
vpb_and :: (b: *Vp_Builder, l: Vp_Val, r: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, vp_opc(.AND), .[l, r], .{}, .[], dl, name); }
vpb_or :: (b: *Vp_Builder, l: Vp_Val, r: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, vp_opc(.OR), .[l, r], vpf_disjoint(false), .[], dl, name); }
vpb_logical_and :: (b: *Vp_Builder, l: Vp_Val, r: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, VPI_LOGICAL_AND, .[l, r], .{}, .[], dl, name); }
vpb_logical_or :: (b: *Vp_Builder, l: Vp_Val, r: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, VPI_LOGICAL_OR, .[l, r], .{}, .[], dl, name); }
vpb_select :: (b: *Vp_Builder, c: Vp_Val, t: Vp_Val, f: Vp_Val, dl: Md_Id = NONE, name := "", flags := Vp_Flags.{}) -> Vp_Rec {
    return vpb_nary(b, vp_opc(.SELECT), .[c, t, f], flags, .[], dl, name);
}
vpb_icmp :: (b: *Vp_Builder, pred: u8, l: Vp_Val, r: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, vp_opc(.ICMP), .[l, r], vpf_cmp(pred), .[], dl, name); }
vpb_fcmp :: (b: *Vp_Builder, pred: u8, l: Vp_Val, r: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, vp_opc(.FCMP), .[l, r], vpf_fcmp(pred, 0), .[], dl, name); }
vpb_ptr_add :: (b: *Vp_Builder, p: Vp_Val, off: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, VPI_PTR_ADD, .[p, off], vpf_gep(0), .[], dl, name); }
vpb_no_wrap_ptr_add :: (b: *Vp_Builder, p: Vp_Val, off: Vp_Val, gep: u32, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, VPI_PTR_ADD, .[p, off], vpf_gep(gep), .[], dl, name); }
vpb_wide_ptr_add :: (b: *Vp_Builder, p: Vp_Val, off: Vp_Val, dl: Md_Id = NONE, name := "") -> Vp_Rec { return vpb_nary(b, VPI_WIDE_PTR_ADD, .[p, off], vpf_gep(0), .[], dl, name); }
// createScalarPhi (VPPhi)
vpb_scalar_phi :: (b: *Vp_Builder, incoming: [] Vp_Val, dl: Md_Id = NONE, name := "", flags := Vp_Flags.{}, result_ty: Type_Id = NONE) -> Vp_Rec {
    ty := result_ty;
    if ty == NONE && incoming.count ty = vp_scalar_type(incoming[0]);
    r := vp_new_single_def(.INSTRUCTION, incoming, ty, NONE, dl);
    vr(r).opcode = vp_opc(.PHI); vr(r).flags = flags; vr(r).name = name;
    return vpb_insert(b, r);
}
// createScalarCast (VPInstructionWithType)
// (flags with optype OTHER = VPIRFlags::getDefaultFlags(Opcode), the overload without explicit flags)
vpb_scalar_cast :: (b: *Vp_Builder, opc: Opcode, v: Vp_Val, ty: Type_Id, dl: Md_Id = NONE, flags_in := Vp_Flags.{}, md: [] Vp_Md = .[]) -> Vp_Rec {
    flags := flags_in;
    if flags.optype == .OTHER flags = vp_default_flags(vp_opc(opc), ty);
    r := vp_new_instruction(vp_opc(opc), .[v], flags, md, dl, "", ty);
    vr(r).with_type = true;
    return vpb_insert(b, r);
}
// createScalarLoad
vpb_scalar_load :: (b: *Vp_Builder, ty: Type_Id, addr: Vp_Val, dl: Md_Id = NONE, md: [] Vp_Md = .[]) -> Vp_Rec {
    r := vp_new_instruction(vp_opc(.LOAD), .[addr], .{}, md, dl, "", ty);
    vr(r).with_type = true;
    return vpb_insert(b, r);
}
// createScalarZExtOrTrunc
vpb_scalar_zext_or_trunc :: (b: *Vp_Builder, v: Vp_Val, ty: Type_Id, src_ty: Type_Id, dl: Md_Id = NONE) -> Vp_Val {
    if ty == src_ty return v;
    opc := ifx type_bits(scalar_type(ty)) < type_bits(scalar_type(src_ty)) then Opcode.TRUNC else .ZEXT;
    return vr(vpb_scalar_cast(b, opc, v, ty, dl, vp_default_flags(vp_opc(opc)))).def;
}
vpb_scalar_sext_or_trunc :: (b: *Vp_Builder, v: Vp_Val, ty: Type_Id, src_ty: Type_Id, dl: Md_Id = NONE) -> Vp_Val {
    if ty == src_ty return v;
    opc := ifx type_bits(scalar_type(ty)) < type_bits(scalar_type(src_ty)) then Opcode.TRUNC else .SEXT;
    return vr(vpb_scalar_cast(b, opc, v, ty, dl, vp_default_flags(vp_opc(opc)))).def;
}
// VPIRFlags::getDefaultFlags
vp_default_flags :: (opcode: u16, result_ty: Type_Id = NONE) -> Vp_Flags {
    if opcode == VPI_CANONICAL_IV_INCREMENT_FOR_PART return vpf_wrap(false, false);
    if opcode == VPI_PTR_ADD || opcode == VPI_WIDE_PTR_ADD return vpf_gep(0);
    if opcode == VPI_COMPUTE_REDUCTION_RESULT fatal("internal: opcode requires explicit flags");
    if !vp_is_ir_opcode(opcode) return .{};
    o := vp_ir_opcode(opcode);
    if o == {
        case .ADD; #through; case .SUB; #through; case .MUL; #through; case .SHL; return vpf_wrap(false, false);
        case .TRUNC; return vpf_trunc(false, false);
        case .OR; return vpf_disjoint(false);
        case .ASHR; #through; case .LSHR; #through; case .UDIV; #through; case .SDIV; return vpf_exact(false);
        case .GEP; return vpf_gep(0);
        case .ZEXT; #through; case .UITOFP; return vpf_nneg(false);
        case .FADD; #through; case .FSUB; #through; case .FMUL; #through; case .FDIV; #through; case .FREM; #through;
        case .FNEG; #through; case .FPEXT; #through; case .FPTRUNC; return vpf_fmf(0);
        case .SELECT; if result_ty != NONE && is_fp_type(scalar_type(result_ty)) return vpf_fmf(0); return .{};
        case .ICMP; #through; case .FCMP; fatal("internal: opcode requires explicit flags");
    }
    return .{};
}

// computeScalarTypeForInstruction (VPlanRecipes.cpp)
vp_compute_scalar_type_for_instruction :: (opcode: u16, ops: [] Vp_Val) -> Type_Id {
    assert(ops.count > 0, "zero-operand VPInstruction opcodes must pass explicit ResultTy");
    op0 := vp_scalar_type(ops[0]);
    if vp_is_ir_opcode(opcode) {
        o := vp_ir_opcode(opcode);
        if o == .SWITCH || o == .STORE return type_simple(.VOID);
        if o == .ICMP || o == .FCMP return type_int(1);
        if o == .SELECT return vp_scalar_type(ops[1]);
        if o == .INSERTELEMENT return op0;
        if o == .EXTRACTVALUE return type_sub(op0, cast(u32) const_int_zext(vp_ir(ops[1])));
        if o == .LOAD || o == .ALLOCA fatal("internal: VPInstruction type must be passed explicitly");
        if o == .CALL return type_sub(glob(vp_ir(ops[vp_called_fn_operand_index_ops(ops)])).value_type, 0);
        return op0;
    }
    if opcode == {
        case VPI_BRANCH_ON_COND; #through; case VPI_BRANCH_ON_TWO_CONDS; #through; case VPI_BRANCH_ON_COUNT; return type_simple(.VOID);
        case VPI_ACTIVE_LANE_MASK; #through; case VPI_MASKED_COND; #through; case VPI_LOGICAL_AND; #through;
        case VPI_LOGICAL_OR; #through; case VPI_ANY_OF; return type_int(1);
        case VPI_EXPLICIT_VECTOR_LENGTH; return type_int(32);
        case VPI_EXTRACT_LANE; return vp_scalar_type(ops[1]);
        case VPI_FIRST_ACTIVE_LANE; #through; case VPI_LAST_ACTIVE_LANE; #through; case VPI_NUM_ACTIVE_LANES; #through;
        case VPI_INCOMING_ALIAS_MASK; fatal("internal: VPInstruction type must be passed explicitly");
    }
    return op0;
}

// getCalledFnOperandIndex: the called function is the last operand (unmasked) or the second to last (masked)
vp_called_fn_operand_index_ops :: (ops: [] Vp_Val) -> s64 {
    n := ops.count;
    last := ops[n - 1];
    if vp_is_ir_value(last) && vkind(vp_ir(last)) == .FUNCTION return n - 1;
    return n - 2;
}
vp_called_fn_operand_index :: (r: Vp_Rec) -> s64 { return vp_called_fn_operand_index_ops(vr(r).ops); }
