// SLPVectorizer: code generation. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (BoUpSLP's
// IRBuilder<TargetFolder> Builder, setInsertPointAfterBundle, gather, ShuffleInstructionBuilder (with
// ShuffleIRBuilder and BaseShuffleAnalysis::createShuffle<Value *>), createBuildVector, vectorizeOperand,
// vectorizeTree(TreeEntry *), ::propagateMetadata, createInsertVector / createExtractVector) and of
// llvm::propagateIRFlags (llvm/lib/Transforms/Utils/LoopUtils.cpp) / llvm::propagateMetadata
// (llvm/lib/Analysis/VectorUtils.cpp).
//
// ShuffleInstructionBuilder is the `.IR` kind of the shared `Bv_Builder` (slp_shuffle.jai): processBuildVector is
// one procedure, and each builder call switches on the kind.

Slp_Gen :: struct {
    b: Irb;                                       // BoUpSLP::Builder (IRBuilder<TargetFolder>, no fast-math flags)
    cb: *Irb;                                     // the builder the sgb_* calls use: &b, or a reduction's own IRBuilder
    cfmf: u32;                                    // its fast-math flags (setFPAttrs of FP-math results)
    gather_seq: [..] Value_Id;                    // SetVector<Instruction *> GatherShuffleExtractSeq
    gather_seq_set: Table(Value_Id, bool);
    cse_blocks: [..] Value_Id;                    // DenseSet<BasicBlock *> CSEBlocks (sorted by DFS number when used)
    postponed_gathers: [..] Te_Id;                // SetVector<const TreeEntry *> PostponedGathers
    last_inst_to_pos: Table(Value_Id, Value_Id);  // LastInstructionToPos
    deleted_list: [..] Value_Id;                  // DeletedInstructions in insertion order (slp.deleted_instructions is the set)
}
slpg: Slp_Gen;

slpg_init :: () {
    slpg = .{};
    slpg.cb = *slpg.b;
    slpg.gather_seq.allocator = temp; slpg.gather_seq_set.allocator = temp; slpg.cse_blocks.allocator = temp;
    slpg.postponed_gathers.allocator = temp; slpg.last_inst_to_pos.allocator = temp; slpg.deleted_list.allocator = temp;
}

// TreeEntry::VectorizedValue is a WeakTrackingVH
te_vv :: (te: Te_Id) -> Value_Id {
    e := *slp.entries[te];
    if !e.has_vv return NONE;
    return vh_get(e.vv);
}
te_set_vv :: (te: Te_Id, v: Value_Id) {
    e := *slp.entries[te];
    if !e.has_vv { e.vv = vh_new(v); e.has_vv = true; return; }
    vh_set(e.vv, v);
}

slpg_add_gather_seq :: (i: Value_Id) {
    if !table_contains(*slpg.gather_seq_set, i) { table_set(*slpg.gather_seq_set, i, true); array_add(*slpg.gather_seq, i); }
}
slpg_add_cse_block :: (bb: Value_Id) { if !slp_has(slpg.cse_blocks, bb) array_add(*slpg.cse_blocks, bb); }
// GatherShuffleExtractSeq.insert(I); CSEBlocks.insert(I->getParent()) for an instruction result
slpg_record :: (v: Value_Id) {
    if !is_inst(v) return;
    slpg_add_gather_seq(v);
    slpg_add_cse_block(inst_block(v));
}

// eraseInstruction(I): only marks it (deleted in ~BoUpSLP)
slp_erase_instruction :: (i: Value_Id) {
    if table_contains(*slp.deleted_instructions, i) return;
    table_set(*slp.deleted_instructions, i, true);
    array_add(*slpg.deleted_list, i);
}

// ---------------------------------------------------------------- the Builder (IRBuilder<TargetFolder>)

sgb_insert :: (i: Value_Id, name: string = "") -> Value_Id {
    if slpg.cfmf != 0 && is_fp_math_inst(i) set_fmf(i, slpg.cfmf);
    return irb_insert(slpg.cb, i, name);
}
sgb_set_before :: (i: Value_Id) { irb_set_before(slpg.cb, i); }
sgb_set_at :: (bb: Value_Id, pt: Value_Id, head := false) { irb_set_at(slpg.cb, bb, pt, head); }
sgb_set_dbg :: (i: Value_Id) { slpg.cb.dbg = get_metadata(i, 0); }
sgb_insert_block :: () -> Value_Id { return slpg.cb.bb; }

// FoldBinOp
sgb_binop :: (opc: Opcode, l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    f := tf_fold_binop(opc, l, r, 0);
    if f != NONE return f;
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    return sgb_insert(i, name);
}
// CreateUnOp
sgb_unop :: (opc: Opcode, v: Value_Id, name: string = "") -> Value_Id {
    if is_const(v) { f := cfo_unary_op_operand(opc, v); if f != NONE return f; }
    i := new_inst(opc, vtype(v), 1);
    set_op(i, 0, v);
    return sgb_insert(i, name);
}
// CreateCast
sgb_cast :: (opc: Opcode, v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id {
    if vtype(v) == dt return v;
    if is_const(v) { f := cfo_cast_operand(opc, v, dt); if f != NONE return f; }
    return sgb_insert(create_cast(opc, v, dt), name);
}
// CreateIntCast
sgb_int_cast :: (v: Value_Id, dt: Type_Id, is_signed: bool, name: string = "") -> Value_Id {
    opc: Opcode = ifx type_bits(scalar_type(vtype(v))) > type_bits(scalar_type(dt)) then .TRUNC else ifx is_signed then .SEXT else .ZEXT;
    return sgb_cast(opc, v, dt, name);
}
// CreateBitOrPointerCast
sgb_bit_or_pointer_cast :: (v: Value_Id, dt: Type_Id) -> Value_Id {
    if vtype(v) == dt return v;
    if is_ptr_or_ptr_vector(vtype(v)) && is_int_or_int_vector(dt) return sgb_cast(.PTRTOINT, v, dt);
    if is_int_or_int_vector(vtype(v)) && is_ptr_or_ptr_vector(dt) return sgb_cast(.INTTOPTR, v, dt);
    return sgb_cast(.BITCAST, v, dt);
}
// CreateCmp (FoldCmp = ConstantFoldCompareInstOperands)
sgb_cmp :: (pred: u8, l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    if is_const(l) && is_const(r) { f := cfo_compare_inst_operands(pred, l, r); if f != NONE return f; }
    if is_fp_predicate(pred) return sgb_insert(create_fcmp(pred, l, r), name);
    return sgb_insert(create_icmp(pred, l, r), name);
}
// CreateSelectWithUnknownProfile(C, True, False, "slp-vectorizer")
sgb_select_unknown_profile :: (c: Value_Id, t: Value_Id, f: Value_Id, name: string = "") -> Value_Id {
    if is_const(c) && is_const(t) && is_const(f) { x := cf_select(c, t, f); if x != NONE return x; }
    i := sgb_insert(create_select(c, t, f), name);
    set_explicitly_unknown_branch_weights_if_profiled(i, "slp-vectorizer");
    return i;
}
// CreateFreeze: never folded
sgb_freeze :: (v: Value_Id, name: string = "") -> Value_Id {
    i := new_inst(.FREEZE, vtype(v), 1);
    set_op(i, 0, v);
    return sgb_insert(i, name);
}
// CreateShuffleVector(V1, V2, Mask) (V2 = NONE: poison)
sgb_shuffle :: (v1: Value_Id, v2_in: Value_Id, mask: [] s32, name: string = "") -> Value_Id {
    v2 := v2_in;
    if v2 == NONE v2 = const_poison(vtype(v1));
    m := mask_to_u32(mask);
    if is_const(v1) && is_const(v2) return cfo_constant(ce_shuffle_vector(v1, v2, m));
    return sgb_insert(create_shuffle(v1, v2, m), name);
}
// CreateInsertElement(Vec, NewElt, uint64 Idx)
sgb_insert_element :: (vec: Value_Id, e: Value_Id, idx: u64, name: string = "") -> Value_Id {
    ix := const_int(ir.t_i64, idx);
    if is_const(vec) && is_const(e) return cfo_constant(ce_insert_element(vec, e, ix));
    i := new_inst(.INSERTELEMENT, vtype(vec), 3);
    set_op(i, 0, vec); set_op(i, 1, e); set_op(i, 2, ix);
    return sgb_insert(i, name);
}
// CreateExtractElement(Vec, Idx)
sgb_extract_element_v :: (vec: Value_Id, ix: Value_Id, name: string = "") -> Value_Id {
    if is_const(vec) && is_const(ix) return cfo_constant(ce_extract_element(vec, ix));
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(vec)), 2);
    set_op(i, 0, vec); set_op(i, 1, ix);
    return sgb_insert(i, name);
}
sgb_extract_element :: (vec: Value_Id, idx: u64, name: string = "") -> Value_Id {
    return sgb_extract_element_v(vec, const_int(ir.t_i64, idx), name);
}
// CreateAlignedLoad / CreateAlignedStore
sgb_load :: (ty: Type_Id, ptr: Value_Id, align: u64, name: string = "") -> Value_Id {
    a := align;
    if a == 0 a = dl_abi_align(ty);
    i := new_inst(.LOAD, ty, 1);
    set_op(i, 0, ptr);
    inst(i).align = a;
    return sgb_insert(i, name);
}
sgb_store :: (v: Value_Id, ptr: Value_Id, align: u64) -> Value_Id {
    i := new_inst(.STORE, ir.t_void, 2);
    set_op(i, 0, v); set_op(i, 1, ptr);
    inst(i).align = align;
    return sgb_insert(i);
}
// CreateGEP(Ty, Ptr, IdxList) (TargetFolder::FoldGEP)
sgb_gep :: (srcty: Type_Id, ptr: Value_Id, idxs: [] Value_Id) -> Value_Id {
    if is_const(ptr) {
        all := true;
        for idxs if !is_const(it) { all = false; break; }
        if all return cfo_constant(ce_gep(srcty, ptr, idxs, 0));
    }
    return sgb_insert(create_gep(srcty, ptr, idxs, 0));
}
sgb_phi :: (ty: Type_Id, reserved: u32) -> Value_Id { return sgb_insert(create_phi(ty, reserved)); }
sgb_extract_value :: (agg: Value_Id, idxs: [] u32) -> Value_Id { return irb_extract_value(slpg.cb, agg, idxs); }

// ---------------------------------------------------------------- IR flags and metadata

// llvm::propagateIRFlags(I, VL, nullptr, IncludeWrapFlags)
slp_propagate_ir_flags :: (i: Value_Id, vl: [] Value_Id, include_wrap: bool) {
    if !is_inst(i) || vl.count == 0 return;
    inter := vl[0];
    if !is_inst(inter) return;
    keep := inst(i).flags & cast(u32) (F_NSW | F_NUW);
    copy_ir_flags(i, inter);
    if !include_wrap && is_overflowing_binop(i) inst(i).flags = (inst(i).flags & ~cast(u32) (F_NSW | F_NUW)) | keep;
    for v: vl if is_inst(v) and_ir_flags(i, v);
}

// llvm::propagateMetadata(Inst, VL): VL are instructions
slp_propagate_metadata :: (i: Value_Id, vl: [] Value_Id) {
    if vl.count == 0 return;
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(vl[0], *all);
    for all {
        name := ir.md_kind_names[it.kind];
        if name != "tbaa" && name != "alias.scope" && name != "noalias" && name != "fpmath" && name != "nontemporal" &&
           name != "invariant.load" && name != "llvm.access.group" && name != "mmra" continue;
        md := it.md;
        if name == "mmra" && !(inst_op(i) == .LOAD || inst_op(i) == .STORE || is_call_base(i) || inst_op(i) == .FENCE ||
                               inst_op(i) == .ATOMICRMW || inst_op(i) == .CMPXCHG) continue;
        for j: 1..vl.count-1 {
            if md == NONE break;
            imd := get_metadata(vl[j], it.kind);
            if name == {
                case "mmra"; md = mmra_combine(md, imd);
                case "tbaa"; md = tbaa_most_generic(md, imd);
                case "alias.scope"; md = md_most_generic_alias_scope(md, imd);
                case "fpmath"; md = md_most_generic_fpmath(md, imd);
                case "llvm.access.group"; md = intersect_access_groups(i, vl[j]);
                case; md = md_intersect(md, imd);
            }
        }
        set_metadata(i, it.kind, md);
    }
}
// ::propagateMetadata(Inst, VL): only the instructions of VL
slp_propagate_metadata_insts :: (i: Value_Id, vl: [] Value_Id) {
    insts: [..] Value_Id; insts.allocator = temp;
    for vl if is_inst(it) array_add(*insts, it);
    slp_propagate_metadata(i, insts);
}

// createInsertVector(Builder, Vec, V, Index, Generator)
slp_create_insert_vector :: (vec_in: Value_Id, v: Value_Id, index: s64, gen: *Bv_Builder = null) -> Value_Id {
    vec := vec_in;
    if pm_poison(vec) && pm_poison(v) return vec;
    sub_vf := cast(s64) slp_num_elements(vtype(v));
    vec_vf := cast(s64) slp_num_elements(vtype(vec));
    mask := new_mask(vec_vf);
    if pm_poison(vec) {
        for k: 0..sub_vf-1 mask[index + k] = cast(s32) k;
        return sgb_shuffle(v, NONE, mask);
    }
    for k: 0..vec_vf-1 mask[k] = cast(s32) k;
    for k: 0..sub_vf-1 mask[index + k] = cast(s32) (vec_vf + k);
    if gen return sib_create_shuffle(gen, vec, v, mask);
    resize := new_mask(vec_vf);
    for k: 0..sub_vf-1 resize[k] = cast(s32) k;
    v2 := sgb_shuffle(v, NONE, resize);
    return sgb_shuffle(vec, v2, mask);
}

// ---------------------------------------------------------------- setInsertPointAfterBundle

slp_set_insert_point_after_bundle :: (te: Te_Id) {
    e := *slp.entries[te];
    front := e.s.main;
    last := slp_last_instruction_in_bundle(te);
    bb := inst_block(last);
    is_phi := inst_op(last) == .PHI;
    pt := last;
    head := false;
    if is_phi {
        pt = block_first_non_phi(bb);
        head = true;
        if pt != NONE && is_landing_pad_block(bb) { pt = inst_next(pt); head = false; }
    }
    c1 := !te_is_gather(te) && e.state != TE_SPLIT_VECTORIZE &&
          (e.does_not_need_to_schedule || (slp_te_has_copyables(te) && !slp_te_is_copyable(te, last) && slp_is_used_outside_block(last)));
    c2 := slpx.gathered_loads_first >= 0 && e.idx >= slpx.gathered_loads_first && !te_is_gather(te) && te_opcode(te) == .LOAD;
    if is_phi || c1 || c2 {
        sgb_set_at(bb, pt, head);
    } else {
        sgb_set_at(bb, inst_next(last));
        found, res := table_find(*slpg.last_inst_to_pos, last);
        if found {
            sgb_set_at(bb, res);
        } else {
            ptr_ty := type_ptr(0);
            res = sgb_load(ptr_ty, const_poison(ptr_ty), 0);
            sgb_set_at(bb, res);
            slp_erase_instruction(res);
            if e.state != TE_SPLIT_VECTORIZE table_set(*slpg.last_inst_to_pos, last, res);
        }
    }
    sgb_set_dbg(front);
}
is_landing_pad_block :: (bb: Value_Id) -> bool {
    f := block_first_non_phi(bb);
    return f != NONE && inst_op(f) == .LANDINGPAD;
}

// ---------------------------------------------------------------- gather

// gather(VL, Root, ScalarTy, CreateShuffle): CreateShuffle is `b`'s createShuffle
slp_gather :: (vl: [] Value_Id, root_in: Value_Id, sty: Type_Id, b: *Bv_Builder) -> Value_Id {
    root := root_in;
    postponed: [..] Value_Id; postponed.allocator = temp;
    postponed_idx: [..] s64; postponed_idx.allocator = temp;
    l := li_loop_for(slp.li, sgb_insert_block());
    check_predecessor :: (inst_bb: Value_Id, insert_bb_in: Value_Id) -> bool {
        insert_bb := insert_bb_in;
        visited: [..] Value_Id; visited.allocator = temp;
        while insert_bb != NONE && insert_bb != inst_bb && !slp_has(visited, insert_bb) {
            array_add(*visited, insert_bb);
            insert_bb = block_single_predecessor(insert_bb);
        }
        return insert_bb != NONE && insert_bb == inst_bb;
    }
    for v, i: vl {
        if !is_inst(v) continue;
        root_inv := root == NONE || !is_inst(root) || !li_contains_inst(slp.li, l, root);
        if (check_predecessor(inst_block(v), sgb_insert_block()) || slp_is_vectorized(v) ||
            (l != NONE && root_inv && li_contains_inst(slp.li, l, v))) && !slp_has(postponed_idx, i) {
            array_add(*postponed_idx, i);
            array_add(*postponed, v);
        }
    }
    vec_ty := slp_widened_type(sty, cast(u64) vl.count);
    vec := const_poison(vec_ty);
    non_consts: [..] s64; non_consts.allocator = temp;
    mask := new_mask(vl.count);
    for * mask it.* = cast(s32) it_index;
    orig_root := root;
    if is_shuffle_inst(root) && pm_poison(op(root, 1)) && vtype(op(root, 0)) == vec_ty {
        sm := shuffle_mask_s32(root);
        mask = mask_copy(sm);
        root = op(root, 0);
    }
    for v, i: vl {
        if slp_has(postponed_idx, i) continue;
        if !slp_is_constant(v) { array_add(*non_consts, i); continue; }
        if pm_poison(v) continue;
        vec = gather_insert_element(vec, v, cast(u32) i, sty);
        mask[i] = cast(s32) (i + vl.count);
    }
    if root != NONE {
        if pm_poison(vec) {
            vec = orig_root;
        } else {
            vec = sib_create_shuffle(b, root, vec, mask);
            if is_inst(orig_root) && !has_uses(orig_root) {
                any := false;
                for k: 0..slp.entries.count-1 if te_vv(cast(Te_Id) k) == orig_root { any = true; break; }
                if !any slp_erase_instruction(orig_root);
            }
        }
    }
    for i: non_consts vec = gather_insert_element(vec, vl[i], cast(u32) i, sty);
    for v, k: postponed vec = gather_insert_element(vec, v, cast(u32) postponed_idx[k], sty);
    return vec;
}

// the CreateInsertElement lambda of gather
gather_insert_element :: (vec_in: Value_Id, v: Value_Id, pos: u32, ty: Type_Id) -> Value_Id {
    vec := vec_in;
    scalar := v;
    if is_inst(scalar) && inst_op(scalar) == .TRUNC && (inst(scalar).flags & F_NUW) != 0 inst(scalar).flags &= ~cast(u32) F_NUW;
    vv := v;   // the V of the lambda after the cast
    if vtype(scalar) != ty {
        x := scalar;
        if is_inst(scalar) && (inst_op(scalar) == .SEXT || inst_op(scalar) == .ZEXT) {
            o := op(scalar, 0);
            if !is_inst(o) || !(slp_is_deleted(o) || slp_is_vectorized(o)) x = o;
        }
        vv = x;
        scalar = sgb_int_cast(x, ty, !is_known_non_negative(scalar, slp_simple_query()));
    }
    if is_vector_type(vtype(scalar)) slp_fail("REVEC gathers");
    vec = sgb_insert_element(vec, scalar, cast(u64) pos);
    if !is_inst(vec) || inst_op(vec) != .INSERTELEMENT return vec;
    ins := vec;
    slpg_add_gather_seq(ins);
    slpg_add_cse_block(inst_block(ins));
    if is_inst(vv) {
        found := TE_NONE;
        for te: slp_get_tree_entries(vv) {
            if !table_contains(*slp.transformed_to_gather_nodes, te) && !table_contains(*slp.deleted_nodes, te) { found = te; break; }
        }
        if found != TE_NONE {
            user_op: Value_Id = NONE;
            if scalar != vv {
                if is_inst(scalar) user_op = scalar;
            } else {
                if is_vector_type(vtype(vv)) slp_fail("REVEC gathers");
                user_op = ins;
            }
            if user_op != NONE {
                lane := te_find_lane_for_value(found, vv);
                array_add(*slpx.external_uses, .{vv, user_op, found, lane});
            }
        }
    }
    return vec;
}

// ---------------------------------------------------------------- ShuffleInstructionBuilder

bv_init_ir :: (b: *Bv_Builder, sty: Type_Id) {
    b.* = .{};
    b.kind = .IR;
    b.sty = sty;
    b.common_mask.allocator = temp; b.in_vectors.allocator = temp; b.bv_values.allocator = temp; b.vectorized_vals.allocator = temp;
}

// ShuffleIRBuilder::createShuffleVector(V1, V2, Mask)
sirb_shuffle2 :: (v1_in: Value_Id, v2_in: Value_Id, mask: [] s32) -> Value_Id {
    v1 := v1_in; v2 := v2_in;
    if vtype(v1) != vtype(v2) {
        if type_bits(type_elem(vtype(v2))) < type_bits(type_elem(vtype(v1))) v2 = sgb_int_cast(v2, vtype(v1), !is_known_non_negative(v2, slp_simple_query()));
        else v1 = sgb_int_cast(v1, vtype(v2), !is_known_non_negative(v1, slp_simple_query()));
    }
    vec := sgb_shuffle(v1, v2, mask);
    slpg_record(vec);
    return vec;
}
// ShuffleIRBuilder::createShuffleVector(V1, Mask)
sirb_shuffle1 :: (v1: Value_Id, mask: [] s32) -> Value_Id {
    if mask.count == 0 return v1;
    vf := mask.count;
    local_vf := cast(s64) type_count(vtype(v1));
    if vf == local_vf && svm_is_identity(mask, vf) return v1;
    vec := sgb_shuffle(v1, NONE, mask);
    slpg_record(vec);
    return vec;
}
// ShuffleIRBuilder::resizeToMatch(V1, V2)
sirb_resize_to_match :: (v1: *Value_Id, v2: *Value_Id) {
    if vtype(v1.*) == vtype(v2.*) return;
    v1vf := cast(s64) type_count(vtype(v1.*)); v2vf := cast(s64) type_count(vtype(v2.*));
    vf := max(v1vf, v2vf); min_vf := min(v1vf, v2vf);
    m := new_mask(vf);
    for k: 0..min_vf-1 m[k] = cast(s32) k;
    o := ifx min_vf == v1vf then v1 else v2;
    o.* = sgb_shuffle(o.*, NONE, m);
    slpg_record(o.*);
}

// BaseShuffleAnalysis::createShuffle<Value *>(V1, V2, Mask, ShuffleIRBuilder, ScalarTy)
bsa_create_shuffle_ir :: (v1_in: Value_Id, v2_in: Value_Id, mask_in: [] s32, sty: Type_Id) -> Value_Id {
    v1 := v1_in; v2 := v2_in;
    if slp_num_elements(sty) != 1 slp_fail("REVEC shuffles");
    mask := mask_copy(mask_in);
    if v2 != NONE sirb_resize_to_match(*v1, *v2);
    vf := mask.count;
    if type_kind(vtype(v1)) == .VECTOR vf = cast(s64) type_count(vtype(v1));
    if v2 != NONE && !all_bits(slp_is_undef_vector(v2, slp_build_use_mask(vf, mask, SLP_USE_MASK_SECOND_ARG), true)) {
        op1 := v1; op2 := v2;
        vf1 := cast(s64) type_count(vtype(v1));
        cm1 := new_mask(mask.count); cm2 := new_mask(mask.count);
        for i: 0..mask.count-1 {
            if mask[i] < vf1 cm1[i] = mask[i];
            else cm2[i] = mask[i] - cast(s32) vf1;
        }
        while true {
            prev1 := op1; prev2 := op2;
            bsa_peek_through_shuffles(*op1, *cm1, false);
            bsa_peek_through_shuffles(*op2, *cm2, false);
            if is_shuffle_inst(op1) && is_shuffle_inst(op2) {
                sv1 := op1; sv2 := op2;
                m1 := shuffle_mask_s32(sv1); m2 := shuffle_mask_s32(sv2);
                ext1 := new_mask(mask.count);
                for i, idx: cm1 if i != PME ext1[idx] = m1[i];
                um1 := slp_build_use_mask(cast(s64) type_count(vtype(op(sv1, 1))), ext1, SLP_USE_MASK_SECOND_ARG);
                ext2 := new_mask(cm2.count);
                for i, idx: cm2 if i != PME ext2[idx] = m2[i];
                um2 := slp_build_use_mask(cast(s64) type_count(vtype(op(sv2, 1))), ext2, SLP_USE_MASK_SECOND_ARG);
                if vtype(op(sv1, 0)) == vtype(op(sv2, 0)) && vtype(op(sv1, 0)) != vtype(sv1) &&
                   all_bits(slp_is_undef_vector(op(sv1, 1), um1)) && all_bits(slp_is_undef_vector(op(sv2, 1), um2)) {
                    op1 = op(sv1, 0); op2 = op(sv2, 0);
                    sm1 := mask_copy(m1);
                    lvf := sm1.count;
                    if type_kind(vtype(op1)) == .VECTOR lvf = cast(s64) type_count(vtype(op1));
                    bsa_combine_masks(lvf, *sm1, cm1);
                    cm1 = sm1;
                    sm2 := mask_copy(m2);
                    lvf = sm2.count;
                    if type_kind(vtype(op2)) == .VECTOR lvf = cast(s64) type_count(vtype(op2));
                    bsa_combine_masks(lvf, *sm2, cm2);
                    cm2 = sm2;
                }
            }
            if prev1 == op1 && prev2 == op2 break;
        }
        sirb_resize_to_match(*op1, *op2);
        vfm := max(cast(s64) type_count(vtype(op1)), cast(s64) type_count(vtype(op2)));
        for i: 0..mask.count-1 {
            if cm2[i] != PME cm1[i] = cm2[i] + cast(s32) (ifx op1 == op2 then 0 else vfm);
        }
        if op1 == op2 && (svm_is_identity(cm1, vfm) ||
                          (svm_is_zero_elt_splat(cm1, vfm) && is_shuffle_inst(op1) && masks_equal(shuffle_mask_s32(op1), cm1)))
            return op1;
        return sirb_shuffle2(op1, ifx op1 == op2 then const_poison(vtype(op1)) else op2, cm1);
    }
    if pm_poison(v1) return const_poison(slp_widened_type(type_elem(vtype(v1)), cast(u64) mask.count));
    is_identity := bsa_peek_through_shuffles(*v1, *mask, true);
    if !is_identity return sirb_shuffle1(v1, mask);
    return v1;
}

// ShuffleInstructionBuilder::createShuffle(V1, V2, Mask)
sib_create_shuffle :: (b: *Bv_Builder, v1: Value_Id, v2: Value_Id, mask: [] s32) -> Value_Id {
    return bsa_create_shuffle_ir(v1, v2, mask, b.sty);
}
// castToScalarTyElem(V, IsSigned): is_signed < 0 = std::nullopt
sib_cast_to_scalar_ty_elem :: (b: *Bv_Builder, v: Value_Id, is_signed: s32 = -1) -> Value_Id {
    vt := vtype(v);
    if type_elem(vt) == scalar_type(b.sty) return v;
    signed := ifx is_signed >= 0 then is_signed == 1 else !is_known_non_negative(v, slp_simple_query());
    return sgb_int_cast(v, type_vector(type_count(vt), scalar_type(b.sty), false), signed);
}
// getVectorizedValue(E)
sib_get_vectorized_value :: (b: *Bv_Builder, te: Te_Id) -> Value_Id {
    vec := te_vv(te);
    if !is_int_or_int_vector(vtype(vec)) return vec;
    any := false;
    for v: slp.entries[te].scalars if !pm_poison(v) && !is_known_non_negative(v, slp_simple_query()) { any = true; break; }
    return sib_cast_to_scalar_ty_elem(b, vec, ifx any then cast(s32) 1 else 0);
}

// adjustExtracts(E, Mask, ShuffleKinds, NumParts, UseVecBaseAsInput)
sib_adjust_extracts :: (b: *Bv_Builder, te: Te_Id, mask: *[..] s32, kinds: [] s64, num_parts: u64) -> (Value_Id, bool) {
    use_vec_base := false;
    unique_bases: [..] Value_Id; unique_bases.allocator = temp;
    vec_base: Value_Id = NONE;
    e := *slp.entries[te];
    vl := vl_copy(e.scalars);
    if e.reorder_indices.count {
        rm := new_mask(); for e.reorder_indices array_add(*rm, cast(s32) it);
        slp_reorder_scalars(*vl, rm);
    }
    for i: 0..mask.count-1 {
        if mask.*[i] == PME continue;
        ei := vl[i];
        vec_base = op(ei, 0);
        tes := slp_get_tree_entries(vec_base);
        if tes.count vec_base = te_vv(tes[0]);
        if !slp_has(unique_bases, vec_base) array_add(*unique_bases, vec_base);
        skip := !has_one_use(ei) || slp_has(slpx.external_uses_as_original_scalar, ei);
        if !skip && e.user_tree_index.user != TE_NONE && e.user_tree_index.edge == EDGE_NONE && !slp_is_vectorized(ei) {
            c1 := 0; for e.scalars if it == ei c1 += 1;
            c2 := 0; for slp.entries[e.user_tree_index.user].scalars if it == ei c2 += 1;
            if c1 != c2 skip = true;
        }
        if !skip && num_parts != 1 {
            c := 0; for vl if it == ei c += 1;
            if c > 1 skip = true;
        }
        if !skip {
            u := ir.v_first_use[ei];
            while u != NONE {
                usr := ir.u_user[u]; u = ir.u_next[u];
                utes := slp_get_tree_entries(usr);
                bad := utes.count == 0 || utes.count > 1;
                if !bad for utes if table_contains(*slp.deleted_nodes, it) || table_contains(*slp.transformed_to_gather_nodes, it) { bad = true; break; }
                if !bad && is_inst(usr) && inst_op(usr) == .GEP && !slp_are_all_users_vectorized(usr) bad = true;
                if !bad && utes.count {
                    cnt := 0;
                    in_vl := slp_has(vl, ei);
                    for k: 0..slp.entries.count-1 if slp.entries[k].user_tree_index.user == utes[0] && in_vl cnt += 1;
                    if cnt != 1 bad = true;
                }
                if bad { skip = true; break; }
            }
        }
        if skip continue;
        slp_erase_instruction(ei);
    }
    if num_parts == 1 || unique_bases.count == 1 return sib_cast_to_scalar_ty_elem(b, vec_base), false;
    use_vec_base = true;
    vec: Value_Id = NONE;
    vec_mask := new_mask(mask.count);
    slice := cast(s64) slp_part_num_elems(cast(u64) vl.count, num_parts);
    for part: 0..cast(s64) num_parts - 1 {
        limit := cast(s64) slp_num_elems(cast(u64) vl.count, cast(u64) slice, cast(u64) part);
        sub_vl := array_view(vl, part * slice, limit);
        sub_mask := array_view(mask.*, part * slice, limit);
        bases: [2] Value_Id = .[NONE, NONE];
        vf: s64 = 0;
        for v, k: sub_vl {
            if sub_mask[k] == PME continue;
            vo := op(v, 0);
            tes := slp_get_tree_entries(vo);
            if tes.count vo = te_vv(tes[0]);
            vf = max(vf, cast(s64) type_count(vtype(vo)));
        }
        for v, k: sub_vl {
            if sub_mask[k] == PME continue;
            vo := op(v, 0);
            tes := slp_get_tree_entries(vo);
            if tes.count vo = te_vv(tes[0]);
            vo = sib_cast_to_scalar_ty_elem(b, vo);
            bases[sub_mask[k] / vf] = vo;
        }
        if bases[0] == NONE continue;
        sub_vec: Value_Id;
        if bases[1] != NONE {
            sub_vec = sib_create_shuffle(b, bases[0], bases[1], sub_mask);
            for * sub_mask if it.* != PME it.* = cast(s32) it_index;
        } else sub_vec = bases[0];
        if vec == NONE {
            vec = sub_vec;
            for k: 0..limit-1 vec_mask[part * slice + k] = sub_mask[k];
        } else {
            new_vf := cast(s64) type_count(vtype(vec));
            if vtype(vec) != vtype(sub_vec) new_vf = max(new_vf, cast(s64) type_count(vtype(sub_vec)));
            for * sub_mask if it.* != PME it.* += cast(s32) new_vf;
            for k: 0..limit-1 vec_mask[part * slice + k] = sub_mask[k];
            vec = sib_create_shuffle(b, vec, sub_vec, vec_mask);
            for * vec_mask if it.* != PME it.* = cast(s32) it_index;
        }
    }
    for k: 0..mask.count-1 mask.*[k] = vec_mask[k];
    return vec, use_vec_base;
}

// needToDelay(E, Deps): NONE = no delay, else the stub load
sib_need_to_delay :: (b: *Bv_Builder, te: Te_Id, deps: [] [..] Te_Id) -> Value_Id {
    all := true;
    for tes: deps for tes if te_vv(it) == NONE { all = false; break; }
    if all return NONE;
    res_ty := slp_widened_type(b.sty, cast(u64) te_vector_factor(te));
    return sgb_load(res_ty, const_poison(type_ptr(0)), 0);
}

// add(V1, V2, Mask)
sib_add_v2 :: (b: *Bv_Builder, v1_in: Value_Id, v2_in: Value_Id, mask: [] s32) {
    v1 := sib_cast_to_scalar_ty_elem(b, v1_in);
    v2 := sib_cast_to_scalar_ty_elem(b, v2_in);
    if b.in_vectors.count == 0 {
        array_add(*b.in_vectors, pu_v(v1)); array_add(*b.in_vectors, pu_v(v2));
        b.common_mask = mask_copy(mask);
        return;
    }
    vec := b.in_vectors[0].v;
    if b.in_vectors.count == 2 {
        vec = sib_create_shuffle(b, vec, b.in_vectors[1].v, b.common_mask);
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
    } else if cast(s64) type_count(vtype(vec)) != mask.count {
        vec = sib_create_shuffle(b, vec, NONE, b.common_mask);
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
    }
    v1 = sib_create_shuffle(b, v1, v2, mask);
    vf := max(bsa_get_vf(b.sty, v1), bsa_get_vf(b.sty, vec));
    for idx: 0..b.common_mask.count-1 if mask[idx] != PME b.common_mask[idx] = cast(s32) (idx + vf);
    b.in_vectors[0] = pu_v(vec);
    if b.in_vectors.count == 2 b.in_vectors[1] = pu_v(v1);
    else array_add(*b.in_vectors, pu_v(v1));
}
// add(V1, Mask, ForExtracts)
sib_add_v :: (b: *Bv_Builder, v1_in: Value_Id, mask: [] s32) {
    v1 := sib_cast_to_scalar_ty_elem(b, v1_in);
    if b.in_vectors.count == 0 {
        array_add(*b.in_vectors, pu_v(v1));
        b.common_mask = mask_copy(mask);
        return;
    }
    it_pos := -1;
    for b.in_vectors if it.v == v1 { it_pos = it_index; break; }
    if it_pos < 0 {
        if b.in_vectors.count == 2 || vtype(b.in_vectors[0].v) != vtype(v1) {
            v := b.in_vectors[0].v;
            if b.in_vectors.count == 2 {
                v = sib_create_shuffle(b, b.in_vectors[0].v, b.in_vectors[1].v, b.common_mask);
                bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
            } else if cast(s64) type_count(vtype(v)) != b.common_mask.count {
                v = sib_create_shuffle(b, b.in_vectors[0].v, NONE, b.common_mask);
                bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
            }
            vf := max(b.common_mask.count, mask.count);
            for idx: 0..b.common_mask.count-1
                if b.common_mask[idx] == PME && mask[idx] != PME
                    b.common_mask[idx] = ifx vtype(v) != vtype(v1) then cast(s32) (idx + vf) else mask[idx] + cast(s32) bsa_get_vf(b.sty, v1);
            if vtype(v) != vtype(v1) v1 = sib_create_shuffle(b, v1, NONE, mask);
            b.in_vectors[0] = pu_v(v);
            if b.in_vectors.count == 2 b.in_vectors[1] = pu_v(v1);
            else array_add(*b.in_vectors, pu_v(v1));
            return;
        }
        for idx: 0..b.common_mask.count-1 {
            if mask[idx] != PME && b.common_mask[idx] == PME { array_add(*b.in_vectors, pu_v(v1)); break; }
        }
    }
    vf: s64 = 0;
    for b.in_vectors vf = max(vf, bsa_get_vf(b.sty, it.v));
    for idx: 0..b.common_mask.count-1
        if mask[idx] != PME && b.common_mask[idx] == PME b.common_mask[idx] = mask[idx] + cast(s32) (ifx it_pos == 0 then 0 else vf);
}
// addOrdered(V1, Order)
sib_add_ordered :: (b: *Bv_Builder, v1: Value_Id, order: [] u32) {
    m := slp_inverse_permutation(order);
    sib_add_v(b, v1, m);
}

// finalize(ExtMask, SubVectors, SubVectorsMask, VF, Action)
sib_finalize :: (b: *Bv_Builder, ext_mask: [] s32, sub_vectors: [] [2] s64, sub_vectors_mask: [] s32, vf: s64 = 0, action: *Pbv_Action = null) -> Value_Id {
    b.is_finalized = true;
    if action {
        vec := b.in_vectors[0].v;
        if b.in_vectors.count == 2 {
            vec = sib_create_shuffle(b, vec, b.in_vectors[1].v, b.common_mask);
            pop(*b.in_vectors);
        } else {
            vec = sib_create_shuffle(b, vec, NONE, b.common_mask);
        }
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
        vec_vf := cast(s64) type_count(vtype(vec));
        if vec_vf < vf {
            rm := new_mask(vf);
            for k: 0..vec_vf-1 rm[k] = cast(s32) k;
            vec = sib_create_shuffle(b, vec, NONE, rm);
        }
        pbv_run_action(b, action, *vec, *b.common_mask);
        b.in_vectors[0] = pu_v(vec);
    }
    if sub_vectors.count {
        vec := b.in_vectors[0].v;
        if b.in_vectors.count == 2 {
            vec = sib_create_shuffle(b, vec, b.in_vectors[1].v, b.common_mask);
            pop(*b.in_vectors);
        } else {
            vec = sib_create_shuffle(b, vec, NONE, b.common_mask);
        }
        bsa_transform_mask_after_shuffle(*b.common_mask, b.common_mask);
        create_sub_vectors :: (b: *Bv_Builder, vec_in: Value_Id, sub_vectors: [] [2] s64) -> Value_Id {
            vec := vec_in;
            for sv: sub_vectors {
                e := cast(Te_Id) sv[0]; idx := sv[1];
                v := sib_get_vectorized_value(b, e);
                insertion_index := idx * cast(s64) slp_num_elements(b.sty);
                orig := b.sty;
                b.sty = scalar_type(b.sty);
                vec = slp_create_insert_vector(vec, v, insertion_index, b);
                b.sty = orig;
                if b.common_mask.count for k: 0..te_vector_factor(e)-1 b.common_mask[idx + k] = cast(s32) (idx + k);
            }
            return vec;
        }
        if sub_vectors_mask.count == 0 {
            vec = create_sub_vectors(b, vec, sub_vectors);
        } else {
            svm := new_mask(b.common_mask.count);
            for sub_vectors_mask svm[it_index] = it;
            for i2, k: b.common_mask if i2 != PME svm[k] = i2 + cast(s32) b.common_mask.count;
            insert_vec := create_sub_vectors(b, const_poison(vtype(vec)), sub_vectors);
            vec = sib_create_shuffle(b, insert_vec, vec, svm);
            bsa_transform_mask_after_shuffle(*b.common_mask, svm);
        }
        b.in_vectors[0] = pu_v(vec);
    }
    if ext_mask.count {
        if b.common_mask.count == 0 b.common_mask = mask_copy(ext_mask);
        else {
            nm := new_mask(ext_mask.count);
            for x, i: ext_mask if x != PME nm[i] = b.common_mask[x];
            b.common_mask = nm;
        }
    }
    if b.common_mask.count == 0 return b.in_vectors[0].v;
    if b.in_vectors.count == 2 return sib_create_shuffle(b, b.in_vectors[0].v, b.in_vectors[1].v, b.common_mask);
    return sib_create_shuffle(b, b.in_vectors[0].v, NONE, b.common_mask);
}

// ---------------------------------------------------------------- createBuildVector / vectorizeTree(E)

// createBuildVector(E, ScalarTy)
slp_create_build_vector :: (te: Te_Id, sty: Type_Id) -> Value_Id {
    e := *slp.entries[te];
    if !(e.state == TE_SPLIT_VECTORIZE && table_contains(*slp.transformed_to_gather_nodes, te)) {
        for cei: e.combined_entries_with_indices slp_vectorize_tree_entry(cast(Te_Id) cei[0]);
    }
    b: Bv_Builder;
    bv_init_ir(*b, sty);
    r := slp_process_build_vector(te, sty, *b);
    return r.v;
}

// vectorizeOperand(E, NodeIdx)
slp_vectorize_operand :: (te: Te_Id, idx: u32) -> Value_Id { return slp_vectorize_tree_entry(slp_get_operand_entry(te, idx)); }

// the FinalShuffle lambda of vectorizeTree(E)
slp_final_shuffle :: (v: Value_Id, te: Te_Id, sty: Type_Id) -> Value_Id {
    if type_kind(sty) == .STRUCT return v;
    e := *slp.entries[te];
    b: Bv_Builder;
    bv_init_ir(*b, sty);
    is_reverse := e.reorder_indices.count && slp_is_reverse_order(e.reorder_indices);
    if (e.state == TE_STRIDED_VECTORIZE && is_reverse) || e.state == TE_COMPRESS_VECTORIZE {
        sib_add_ordered(*b, v, .[]);
    } else if te_opcode(te) == .STORE && (e.state == TE_VECTORIZE || e.state == TE_STRIDED_VECTORIZE || e.state == TE_EXPAND_VECTORIZE) {
        m := new_mask(); for e.reorder_indices array_add(*m, cast(s32) it);
        sib_add_v(*b, v, m);
    } else {
        sib_add_ordered(*b, v, e.reorder_indices);
    }
    subs: [..] [2] s64; subs.allocator = temp;
    for cei: e.combined_entries_with_indices array_add(*subs, .[cast(s64) cei[0], cast(s64) cei[1]]);
    return sib_finalize(*b, e.reuse_shuffle_indices, subs, .[]);
}

// GetOperandSignedness(Idx) of vectorizeTree(E)
slp_operand_signedness :: (te: Te_Id, idx: u32) -> bool {
    ope := slp_get_operand_entry(te, idx);
    return slp_entry_signedness(ope, slp.entries[te].scalars[0]);
}
slp_entry_signedness :: (ope: Te_Id, v: Value_Id) -> bool {
    found, bw := slp_min_bw_of(ope);
    if found return bw.signed;
    // any_of(OpE->Scalars, ...) with the `isa<PoisonValue>(V)` of LLVM testing the captured V (E->Scalars.front())
    if pm_poison(v) return false;
    for r: slp.entries[ope].scalars if !is_known_non_negative(r, slp_simple_query()) return true;
    return false;
}

// the PropagateIRFlags lambda of vectorizeTree(E)
slp_propagate_flags_for :: (te: Te_Id, v: Value_Id, opcode_in: Opcode = .NONE_OP, vl_in: [] Value_Id = .[]) -> Value_Id {
    e := *slp.entries[te];
    scalars := ifx vl_in.count == 0 then cast([] Value_Id) e.scalars else vl_in;
    has_min_bw := table_contains(*slpx.min_bws, te);
    uniq: [..] Value_Id; uniq.allocator = temp;
    for s: scalars {
        if !is_inst(s) continue;
        if slp_te_has_copyables(te) && slp_te_is_copyable(te, s) continue;
        if !slp_has(uniq, s) array_add(*uniq, s);
    }
    opcode := opcode_in;
    if opcode == .NONE_OP opcode = te_opcode(te);
    slp_propagate_ir_flags(v, uniq, !has_min_bw);
    if !is_inst(v) return v;
    i := v;
    slp_propagate_metadata(i, uniq);
    if slp_te_has_copyables(te) && is_fp_math_inst(i) {
        all_nnan := true; all_ninf := true;
        for s: scalars {
            if !slp_te_is_copyable(te, s) continue;
            if is_inst(s) && is_fp_math_inst(s) {
                f := get_fmf(s);
                all_nnan &= (f & FMF_NNAN) != 0; all_ninf &= (f & FMF_NINF) != 0;
                continue;
            }
            if vkind(s) == .C_FP {
                all_nnan &= !apf_is_nan(apf_from_const(s)); all_ninf &= !apf_is_inf(apf_from_const(s));
                continue;
            }
            all_nnan = false; all_ninf = false;
            break;
        }
        if !all_nnan set_fmf(i, get_fmf(i) & ~cast(u32) FMF_NNAN);
        if !all_ninf set_fmf(i, get_fmf(i) & ~cast(u32) FMF_NINF);
    }
    if !has_min_bw && opcode == .SUB {
        any := slp_te_has_copyables(te);
        if !any for s: scalars if !is_inst(s) || slp_is_commutative(s) { any = true; break; }
        if any && is_overflowing_binop(i) set_nuw(i, false);
    }
    if !has_min_bw && (opcode == .ADD || opcode == .SUB) {
        for s: uniq {
            so := inst_op(s);
            if so == opcode || (so != .ADD && so != .SUB) continue;
            for k: 0..cast(s64) nops(s) - 1 {
                c := op(s, cast(u32) k);
                if vkind(c) != .C_INT || ap_is_zero(const_ap(c)) continue;
                if is_overflowing_binop(i) set_nuw(i, false);
                if ap_is_min_signed(const_ap(c)) && is_overflowing_binop(i) set_nsw(i, false);
            }
        }
    }
    if !has_min_bw && opcode == .SHL {
        any := false;
        for s: uniq {
            if inst_op(s) != .MUL continue;
            for k: 0..cast(s64) nops(s) - 1 {
                c := op(s, cast(u32) k);
                if vkind(c) == .C_INT && ap_is_min_signed(const_ap(c)) { any = true; break; }
            }
            if any break;
        }
        if any && is_overflowing_binop(i) set_nsw(i, false);
    }
    if inst_op(i) == .ICMP && !has_min_bw inst(i).flags &= ~cast(u32) F_EXACT;   // setSameSign(false)
    return i;
}

// vectorizeTree(TreeEntry *E)
slp_vectorize_tree_entry :: (te: Te_Id) -> Value_Id {
    saved := slpg.b;   // InsertPointGuard
    defer slpg.b = saved;
    e := *slp.entries[te];
    v0 := e.scalars[0];
    sty := slp_get_value_type(v0);
    has_bw, bw := slp_min_bw_of(te);
    if has_bw {
        vt := sty;
        sty = type_int(cast(u32) bw.bits);
        if is_vector_type(vt) sty = slp_widened_type(sty, type_count(vt));
    }
    if te_vv(te) != NONE return te_vv(te);
    vec_ty := slp_widened_type(sty, cast(u64) e.scalars.count);
    if te_is_gather(te) || table_contains(*slp.transformed_to_gather_nodes, te) {
        if te_has_state(te) && e.idx == 0 && !slpx.has_user_ignore_list slp_set_insert_point_after_bundle(te);
        vec := slp_create_build_vector(te, sty);
        te_set_vv(te, vec);
        return vec;
    }
    if e.state == TE_SPLIT_VECTORIZE {
        slp_set_insert_point_after_bundle(te);
        e = *slp.entries[te];
        t1 := cast(Te_Id) e.combined_entries_with_indices[0][0];
        t2 := cast(Te_Id) e.combined_entries_with_indices[e.combined_entries_with_indices.count - 1][0];
        off2 := cast(s64) e.combined_entries_with_indices[e.combined_entries_with_indices.count - 1][1];
        op1 := slp_vectorize_tree_entry(t1);
        op2 := slp_vectorize_tree_entry(t2);
        e = *slp.entries[te];
        if type_elem(vtype(op1)) != scalar_type(sty) op1 = sgb_int_cast(op1, slp_widened_type(sty, type_count(vtype(op1))), slp_entry_signedness(t1, v0));
        if type_elem(vtype(op2)) != scalar_type(sty) op2 = sgb_int_cast(op2, slp_widened_type(sty, type_count(vtype(op2))), slp_entry_signedness(t2, v0));
        if e.reorder_indices.count == 0 {
            m := new_mask(te_vector_factor(te));
            for k: 0..off2-1 m[k] = cast(s32) k;
            if slp_num_elements(sty) != 1 slp_fail("REVEC split nodes");
            vec := sgb_shuffle(op1, NONE, m);
            vec = slp_create_insert_vector(vec, op2, off2);
            te_set_vv(te, vec);
            return vec;
        }
        common_vf := max(te_vector_factor(t1), te_vector_factor(t2));
        if cast(s64) slp_num_elements(vtype(op1)) != common_vf {
            m := new_mask(common_vf);
            for k: 0..te_vector_factor(t1)-1 m[k] = cast(s32) k;
            op1 = sgb_shuffle(op1, NONE, m);
        }
        if cast(s64) slp_num_elements(vtype(op2)) != common_vf {
            m := new_mask(common_vf);
            for k: 0..te_vector_factor(t2)-1 m[k] = cast(s32) k;
            op2 = sgb_shuffle(op2, NONE, m);
        }
        vec := sgb_shuffle(op1, op2, te_split_mask(te));
        te_set_vv(te, vec);
        return vec;
    }
    shuffle_or_op := ifx is_alt_shuffle(e.s) then cast(s32) Opcode.SHUFFLEVECTOR else cast(s32) te_opcode(te);
    if !is_alt_shuffle(e.s) && e.combined_op >= TE_REDUCED_BITCAST return slp_vectorize_reduced_bitcast(te, sty);
    vl0 := e.s.main;
    o := cast(Opcode) shuffle_or_op;
    if o == {
    case .PHI;
        ph := vl0;
        bb := inst_block(ph);
        sgb_set_at(bb, block_first_non_phi(bb), true);
        slpg.b.dbg = get_metadata(ph, 0);
        new_phi := sgb_phi(vec_ty, phi_num_incoming(ph));
        v := new_phi;
        fip := block_first_insertion_pt(bb);
        sgb_set_at(bb, fip, true);
        slpg.b.dbg = get_metadata(ph, 0);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        if phi_num_incoming(new_phi) != 0 return new_phi;
        visited_bbs: [..] Value_Id; visited_bbs.allocator = temp;
        visited_idx: [..] u32; visited_idx.allocator = temp;
        for i: 0..phi_num_incoming(ph)-1 {
            ibb := phi_block(ph, i);
            if phi_num_incoming(new_phi) == phi_num_incoming(ph) return new_phi;
            prev := -1;
            for visited_bbs if it == ibb { prev = it_index; break; }
            if prev < 0 { array_add(*visited_bbs, ibb); array_add(*visited_idx, i); }
            else {
                ote := slp_get_operand_entry(te, i);
                if te_is_gather(ote) || table_contains(*slp.deleted_nodes, ote) || table_contains(*slp.transformed_to_gather_nodes, ote) {
                    vec_op := phi_value(new_phi, visited_idx[prev]);
                    phi_add_incoming(new_phi, vec_op, ibb);
                    te_set_vv(ote, vec_op);
                    continue;
                }
            }
            sgb_set_before(block_terminator(ibb));
            slpg.b.dbg = get_metadata(ph, 0);
            vec := slp_vectorize_operand(te, i);
            if vec_ty != vtype(vec) vec = sgb_int_cast(vec, vec_ty, slp_operand_signedness(te, i));
            phi_add_incoming(new_phi, vec, ibb);
        }
        return te_vv(te);
    case .EXTRACTELEMENT;
        v := slp.entries[te].operands[0][0];
        slp_set_insert_point_after_bundle(te);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .EXTRACTVALUE;
        if e.struct_ev_indices.count {
            slp_set_insert_point_after_bundle(te);
            sv := slp_vectorize_operand(te, 0);
            sv = sgb_extract_value(sv, e.struct_ev_indices);
            if is_inst(sv) slp_propagate_metadata(sv, slp.entries[te].scalars);
            sv = slp_final_shuffle(sv, te, sty);
            te_set_vv(te, sv);
            return sv;
        }
        li := slp.entries[te].operands[0][0];
        sgb_set_before(li);
        ld := sgb_load(vec_ty, op(li, 0), inst(li).align);
        nv := slp_propagate_flags_for(te, ld);
        nv = slp_final_shuffle(nv, te, sty);
        te_set_vv(te, nv);
        return nv;
    case .INSERTVALUE; #through;
    case .INSERTELEMENT;
        return slp_vectorize_insert(te, sty, o);
    case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through; case .FPEXT; #through;
    case .PTRTOINT; #through; case .INTTOPTR; #through; case .SITOFP; #through; case .UITOFP; #through; case .TRUNC; #through;
    case .FPTRUNC; #through; case .BITCAST;
        slp_set_insert_point_after_bundle(te);
        in_vec := slp_vectorize_operand(te, 0);
        ci := vl0;
        vec_opc := inst_op(ci);
        src_sty := type_elem(vtype(in_vec));
        src_ote := slp_get_operand_entry(te, 0);
        src_has, src_bw := slp_min_bw_of(src_ote);
        if !is_fp_type(scalar_type(sty)) && !is_fp_type(src_sty) && (src_has || has_bw || src_sty != scalar_type(vtype(op(ci, 0)))) {
            src_sz := dl_type_size_bits(src_sty);
            if src_has src_sz = src_bw.bits;
            sz := dl_type_size_bits(scalar_type(sty));
            if sz == src_sz vec_opc = .BITCAST;
            else if sz < src_sz vec_opc = .TRUNC;
            else if has_bw vec_opc = ifx bw.signed then .SEXT else .ZEXT;
            else if src_has vec_opc = ifx src_bw.signed then .SEXT else .ZEXT;
        } else if vec_opc == .SITOFP && src_has && !src_bw.signed {
            vec_opc = .UITOFP;
        } else if vec_opc == .BITCAST && src_has && is_fp_type(scalar_type(sty)) {
            orig_src := slp_widened_type(vtype(op(ci, 0)), cast(u64) slp.entries[te].scalars.count);
            in_vec = sgb_int_cast(in_vec, orig_src, src_bw.signed);
        }
        v: Value_Id;
        if vec_opc != o && vec_opc == .BITCAST v = in_vec;
        else v = sgb_cast(vec_opc, in_vec, vec_ty);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .FCMP; #through; case .ICMP;
        slp_set_insert_point_after_bundle(te);
        l := slp_vectorize_operand(te, 0);
        r := slp_vectorize_operand(te, 1);
        if vtype(l) != vtype(r) {
            lbw := type_bits(type_elem(vtype(l))); rbw := type_bits(type_elem(vtype(r)));
            signed := cmp_is_signed(inst(vl0).pred);
            req_bits :: (c: Value_Id, signed: bool) -> u64 {
                a := const_ap(c);
                return ifx signed then cast(u64) ap_significant_bits(a) else cast(u64) ap_active_bits(a);
            }
            e = *slp.entries[te];
            op1 := e.operands[1]; op0 := e.operands[0];
            c1 := false;
            if lbw < rbw {
                if !slp_all_constant(op1) c1 = true;
                else for x: op1 if vkind(x) != .C_INT || req_bits(x, signed) > lbw { c1 = true; break; }
            }
            if !c1 && lbw > rbw && slp_all_constant(op0) {
                all := true;
                for x: op1 if vkind(x) != .C_INT || req_bits(x, signed) > rbw { all = false; break; }
                c1 = all;
            }
            if c1 l = sgb_int_cast(l, vtype(r), slp_operand_signedness(te, 0));
            else r = sgb_int_cast(r, vtype(l), slp_operand_signedness(te, 1));
        }
        v := sgb_cmp(inst(vl0).pred, l, r);
        v = slp_propagate_flags_for(te, v);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .SELECT;
        slp_set_insert_point_after_bundle(te);
        cond := slp_vectorize_operand(te, 0);
        tv := slp_vectorize_operand(te, 1);
        fv := slp_vectorize_operand(te, 2);
        if vtype(tv) != vec_ty tv = sgb_int_cast(tv, vec_ty, slp_operand_signedness(te, 1));
        if vtype(fv) != vec_ty fv = sgb_int_cast(fv, vec_ty, slp_operand_signedness(te, 2));
        cn := slp_num_elements(vtype(cond)); tn := slp_num_elements(vtype(tv));
        if cn != tn slp_fail("REVEC select condition replication");
        v := sgb_select_unknown_profile(cond, tv, fv);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .FNEG;
        slp_set_insert_point_after_bundle(te);
        x := slp_vectorize_operand(te, 0);
        v := sgb_unop(.FNEG, x);
        v = slp_propagate_flags_for(te, v);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .FREEZE;
        slp_set_insert_point_after_bundle(te);
        x := slp_vectorize_operand(te, 0);
        if vtype(x) != vec_ty x = sgb_int_cast(x, vec_ty, slp_operand_signedness(te, 0));
        v := sgb_freeze(x);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through; case .MUL; #through;
    case .FMUL; #through; case .UDIV; #through; case .SDIV; #through; case .FDIV; #through; case .UREM; #through;
    case .SREM; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through;
    case .AND; #through; case .OR; #through; case .XOR;
        slp_set_insert_point_after_bundle(te);
        lhs := slp_vectorize_operand(te, 0);
        rhs := slp_vectorize_operand(te, 1);
        if o == .AND && has_bw {
            e = *slp.entries[te];
            for k: 0..e.operands.count-1 {
                all := true;
                for x: e.operands[k] if vkind(x) != .C_INT || cast(u64) ap_cto(const_ap(x)) < bw.bits { all = false; break; }
                if all {
                    v := slp_final_shuffle(ifx k == 0 then rhs else lhs, te, sty);
                    te_set_vv(te, v);
                    return v;
                }
            }
        }
        if vtype(lhs) != vec_ty lhs = sgb_int_cast(lhs, vec_ty, slp_operand_signedness(te, 0));
        if vtype(rhs) != vec_ty rhs = sgb_int_cast(rhs, vec_ty, slp_operand_signedness(te, 1));
        v := sgb_binop(te_opcode(te), lhs, rhs);
        v = slp_propagate_flags_for(te, v);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .LOAD;
        slp_set_insert_point_after_bundle(te);
        e = *slp.entries[te];
        li := vl0;
        v: Value_Id;
        if e.state == TE_VECTORIZE {
            new_li := sgb_load(vec_ty, op(li, 0), inst(li).align);
            v = slp_propagate_flags_for(te, new_li);
        } else if e.state == TE_COMPRESS_VECTORIZE {
            found, mc := table_find(*slpx.compress_data, te);
            if !found fatal("internal: slp: no CompressEntryToData for a compressed load node");
            align := inst(li).align;
            new_li: Value_Id;
            if mc.is_masked {
                lvf := cast(s64) slp_num_elements(mc.load_vec_ty);
                vals: [..] Value_Id; vals.allocator = temp;
                for 1..lvf / cast(s64) slp_num_elements(vtype(li)) array_add(*vals, const_int(ir.t_i1, 0));
                for mc.compress_mask vals[it] = const_int(ir.t_i1, 1);
                if is_vector_type(vtype(li)) slp_fail("REVEC masked loads");
                ptr := op(li, 0);
                f := get_or_insert_intrinsic_declaration(IID_MASKED_LOAD, .[mc.load_vec_ty, vtype(ptr)]);
                fty := glob(f).value_type;
                c := new_inst(.CALL, func_ret(fty), 4);
                inst(c).ty2 = fty;
                set_op(c, 0, ptr); set_op(c, 1, const_vector_of(vals)); set_op(c, 2, const_poison(mc.load_vec_ty)); set_op(c, 3, f);
                new_li = sgb_insert(c);
                add_param_align(new_li, 0, align);
            } else {
                new_li = sgb_load(mc.load_vec_ty, op(li, 0), align);
            }
            new_li = slp_propagate_flags_for(te, new_li);
            v = sgb_shuffle(new_li, NONE, mc.compress_mask);
        } else if e.state == TE_SCATTER_VECTORIZE {
            vec_ptr := slp_vectorize_operand(te, 0);
            if is_vector_type(sty) slp_fail("REVEC masked gathers");
            common_align: u64 = 0;
            for x: slp.entries[te].scalars if is_inst(x) && inst_op(x) == .LOAD { a := inst(x).align; if common_align == 0 || a < common_align common_align = a; }
            n := slp_num_elements(vec_ty);
            ones: [..] Value_Id; ones.allocator = temp;
            for 1..n array_add(*ones, const_int(ir.t_i1, 1));
            f := get_or_insert_intrinsic_declaration(IID_MASKED_GATHER, .[vec_ty, vtype(vec_ptr)]);
            fty := glob(f).value_type;
            c := new_inst(.CALL, func_ret(fty), 4);
            inst(c).ty2 = fty;
            set_op(c, 0, vec_ptr); set_op(c, 1, const_vector_of(ones)); set_op(c, 2, const_poison(vec_ty)); set_op(c, 3, f);
            new_li := sgb_insert(c);
            add_param_align(new_li, 0, common_align);
            v = slp_propagate_flags_for(te, new_li);
        } else slp_fail("vectorizeTree of strided load nodes");
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .STORE;
        si := vl0;
        slp_set_insert_point_after_bundle(te);
        vec_value := slp_vectorize_operand(te, 0);
        if vtype(vec_value) != vec_ty vec_value = sgb_int_cast(vec_value, vec_ty, slp_operand_signedness(te, 0));
        vec_value = slp_final_shuffle(vec_value, te, sty);
        st: Value_Id;
        if slp.entries[te].state == TE_EXPAND_VECTORIZE {
            found, mst := table_find(*slpx.expand_store_ty, te);
            if !found fatal("internal: slp: expanded store without a masked store type");
            e = *slp.entries[te];
            common_align: u64 = 0;
            for x: e.scalars { a := inst(x).align; if common_align == 0 || a < common_align common_align = a; }
            expand_mask := e.reuse_shuffle_indices;
            vals: [..] Value_Id; vals.allocator = temp;
            for expand_mask array_add(*vals, const_int(ir.t_i1, ifx it != PME then cast(u64) 1 else 0));
            base_ptr := op(e.scalars[0], 1);
            f := get_or_insert_intrinsic_declaration(IID_MASKED_STORE, .[mst, vtype(base_ptr)]);
            fty := glob(f).value_type;
            c := new_inst(.CALL, func_ret(fty), 4);
            inst(c).ty2 = fty;
            set_op(c, 0, vec_value); set_op(c, 1, base_ptr); set_op(c, 2, const_vector_of(vals)); set_op(c, 3, f);
            st = sgb_insert(c);
            add_param_align(st, 1, common_align);
        } else {
            if slp.entries[te].state != TE_VECTORIZE slp_fail("vectorizeTree of strided store nodes");
            st = sgb_store(vec_value, op(si, 1), inst(si).align);
        }
        v := slp_propagate_flags_for(te, st);
        te_set_vv(te, v);
        return v;
    case .GEP;
        gep0 := vl0;
        slp_set_insert_point_after_bundle(te);
        op0 := slp_vectorize_operand(te, 0);
        op_vecs: [..] Value_Id; op_vecs.allocator = temp;
        for j: 1..cast(s64) nops(gep0) - 1 array_add(*op_vecs, slp_vectorize_operand(te, cast(u32) j));
        v := sgb_gep(inst(gep0).ty2, op0, op_vecs);
        if is_inst(v) && inst_op(v) == .GEP v = slp_propagate_flags_for(te, v);
        v = slp_final_shuffle(v, te, sty);
        te_set_vv(te, v);
        return v;
    case .CALL;
        return slp_vectorize_call(te, sty, vec_ty, has_bw, bw);
    case .SHUFFLEVECTOR;
        return slp_vectorize_alt_shuffle(te, sty, vec_ty, has_bw, bw);
    }
    slp_fail(tprint("vectorizeTree of opcode %", o));
    return NONE;
}

// the InsertValue / InsertElement case of vectorizeTree(E)
slp_vectorize_insert :: (te: Te_Id, sty_in: Type_Id, o: Opcode) -> Value_Id {
    e := *slp.entries[te];
    ope := slp_get_operand_entry(te, 1);
    if ope != TE_NONE && !te_is_gather(ope) && te_has_state(ope) && !slp_te_has_copyables(ope)
        sgb_set_before(e.scalars[e.scalars.count - 1]);
    else slp_set_insert_point_after_bundle(te);
    v := slp_vectorize_operand(te, 1);
    e = *slp.entries[te];
    sty := vtype(e.operands[1][0]);
    if type_elem(vtype(v)) != sty {
        found, bw := slp_min_bw_of(slp_get_operand_entry(te, 1));
        v = sgb_int_cast(v, slp_widened_type(sty, type_count(vtype(v))), bw.signed);
    }
    first_insert: Value_Id = NONE;
    for x: e.scalars if !slp_has(e.scalars, op(x, 0)) { first_insert = x; break; }
    num_scalars := e.scalars.count;
    src_vec_ty := slp_insert_build_vector_src_ty(te);
    num_elts := cast(s64) slp_num_elements(src_vec_ty);
    _, off := slp_element_index(e.s.main);
    offset := cast(s64) off;
    mask: [..] s32;
    if e.reorder_indices.count {
        mask = slp_inverse_permutation(e.reorder_indices);
        for k: 0..num_elts - num_scalars - 1 array_add(*mask, PME);
    } else {
        mask = new_mask(num_elts);
        for k: 0..num_scalars-1 mask[k] = cast(s32) k;
    }
    is_identity := true;
    prev_mask := mask;
    mask = new_mask(num_elts);
    for i: 0..num_scalars-1 {
        scalar := e.scalars[prev_mask[i]];
        _, ii := slp_element_index(scalar);
        insert_idx := cast(s64) ii;
        is_identity &= insert_idx - offset == i;
        mask[insert_idx - offset] = cast(s32) i;
    }
    if !is_identity || num_elts != num_scalars {
        v2: Value_Id = NONE;
        is_v_non_poisonous := !slp_is_constant(v) && is_guaranteed_not_to_be_poison(v, slp.ac);
        insert_mask := mask_copy(mask);
        if num_elts != num_scalars && offset == 0 {
            ins := e.s.main;
            while true {
                ok, ix := slp_element_index(ins);
                if !ok break;
                if insert_mask[ix] == PME insert_mask[ix] = cast(s32) ix;
                if !has_one_use(ins) break;
                prv := ins;
                ins = unique_undroppable_user(ins);
                if !is_inst(ins) || op(ins, 0) != prv break;
            }
            use_mask := slp_build_use_mask(num_elts, insert_mask, SLP_USE_MASK_UNDEFS_AS_MASK);
            is_first_poison := slp_is_undef_vector(op(first_insert, 0), use_mask, true);
            is_first_undef := slp_is_undef_vector(op(first_insert, 0), use_mask);
            if !all_bits(is_first_poison) {
                idx := 0;
                for i: 0..num_elts-1 {
                    if insert_mask[i] == PME && !is_first_poison[i] && is_first_undef[i] {
                        if is_v_non_poisonous {
                            insert_mask[i] = cast(s32) (ifx i < num_scalars then i else 0);
                            continue;
                        }
                        if v2 == NONE v2 = const_undef(vtype(v));
                        if idx >= num_scalars idx = num_scalars - 1;
                        insert_mask[i] = cast(s32) (num_scalars + idx);
                        idx += 1;
                    } else if insert_mask[i] != PME && mask[i] == PME {
                        insert_mask[i] = PME;
                    }
                }
            } else {
                insert_mask = mask_copy(mask);
            }
        }
        if v2 == NONE v2 = const_poison(vtype(v));
        v = sgb_shuffle(v, v2, insert_mask);
        slpg_record(v);
    }
    insert_mask := new_mask(num_elts);
    for i: 0..num_elts-1 if mask[i] != PME insert_mask[offset + i] = cast(s32) i;
    use_mask := slp_build_use_mask(num_elts, insert_mask, SLP_USE_MASK_UNDEFS_AS_MASK);
    is_first_undef := slp_is_undef_vector(op(first_insert, 0), use_mask);
    last_name := ir.v_name[e.scalars[e.scalars.count - 1]];
    if (!is_identity || offset != 0 || !all_bits(is_first_undef)) && num_elts != num_scalars {
        if all_bits(is_first_undef) {
            if !svm_is_identity(insert_mask, num_elts) {
                is_first_poison := slp_is_undef_vector(op(first_insert, 0), use_mask, true);
                if !all_bits(is_first_poison) {
                    for i: 0..num_elts-1 if insert_mask[i] == PME && !is_first_poison[i] insert_mask[i] = cast(s32) (i + num_elts);
                }
                v = sgb_shuffle(v, ifx all_bits(is_first_poison) then const_poison(vtype(v)) else op(first_insert, 0), insert_mask, name_ref(last_name));
                slpg_record(v);
            }
        } else {
            is_first_poison := slp_is_undef_vector(op(first_insert, 0), use_mask, true);
            for i: 0..num_elts-1 {
                if insert_mask[i] == PME insert_mask[i] = ifx is_first_poison[i] then PME else cast(s32) i;
                else insert_mask[i] += cast(s32) num_elts;
            }
            v = sgb_shuffle(op(first_insert, 0), v, insert_mask, name_ref(last_name));
            slpg_record(v);
        }
    }
    if o == .INSERTVALUE && !slp_can_vector_store_insert_value(te) {
        agg_ty := vtype(slp.entries[te].s.main);
        slot_align := max(dl_pref_align(vtype(v)), dl_pref_align(agg_ty));
        saved := slpg.b;   // InsertPointGuard + SetInsertPointPastAllocas(F) (the debug location stays)
        entry := fn_entry(slp.f);
        slpg.b.bb = entry; slpg.b.pt = block_first_non_phi_or_dbg_or_alloca(entry); slpg.b.head = false;
        slot := sgb_insert(create_alloca_unlinked(agg_ty, 0, dl_pref_align(agg_ty)), "vec2struct.slot");
        inst_set_align(slot, slot_align);
        slpg.b = saved;
        sgb_store(v, slot, slot_align);
        v = sgb_load(agg_ty, slot, slot_align, "vec2struct");
    }
    te_set_vv(te, v);
    return v;
}

// the Call case of vectorizeTree(E)
slp_vectorize_call :: (te: Te_Id, sty: Type_Id, vec_ty: Type_Id, has_bw: bool, bw: Min_Bw) -> Value_Id {
    ci := slp.entries[te].s.main;
    slp_set_insert_point_after_bundle(te);
    id := get_vector_intrinsic_id_for_call(ci);
    arg_tys := slp_build_intrinsic_arg_types(ci, id, slp_num_elements(vec_ty), ifx has_bw then cast(u32) bw.bits else 0);
    int_cost, lib_cost := slp_vector_call_costs(ci, vec_ty, arg_tys);
    use_intrinsic := id != NOT_INTRINSIC && int_cost <= lib_cost;
    op_vecs: [..] Value_Id; op_vecs.allocator = temp;
    tys_for_decl: [..] Type_Id; tys_for_decl.allocator = temp;
    if use_intrinsic && slp_overload_type_at_arg(id, -1) {
        for ct, ci_: contained_types(vec_ty) if slp_struct_return_overload_at_field(id, cast(s32) ci_) array_add(*tys_for_decl, ct);
    }
    for i: 0..cast(s64) call_num_args(ci) - 1 {
        if use_intrinsic && vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) i) {
            scalar_arg := call_arg(ci, cast(u32) i);
            if id == IID_ABS && has_bw && bw.bits < dl_type_size_bits(vtype(ci)) scalar_arg = const_int(ir.t_i1, 0);
            array_add(*op_vecs, scalar_arg);
            if slp_overload_type_at_arg(id, cast(s32) i) array_add(*tys_for_decl, vtype(scalar_arg));
            continue;
        }
        op_vec := slp_vectorize_operand(te, cast(u32) i);
        scalar_arg := call_arg(ci, cast(u32) i);
        if type_elem(vtype(op_vec)) != scalar_type(vtype(scalar_arg)) && !has_bw {
            cast_ty := slp_widened_type(vtype(scalar_arg), slp_num_elements(vec_ty));
            op_vec = sgb_int_cast(op_vec, cast_ty, slp_operand_signedness(te, cast(u32) i));
        } else if has_bw {
            op_vec = sgb_int_cast(op_vec, vec_ty, slp_operand_signedness(te, cast(u32) i));
        }
        array_add(*op_vecs, op_vec);
        if use_intrinsic && slp_overload_type_at_arg(id, cast(s32) i) array_add(*tys_for_decl, vtype(op_vec));
    }
    cf: Value_Id;
    if !use_intrinsic {
        shape := vf_shape_get(inst(ci).ty2, cast(u32) slp_num_elements(vec_ty), false, false);
        cf = vfdb_get_vectorized_function(ci, *shape);
    } else {
        cf = get_or_insert_intrinsic_declaration(id, tys_for_decl);
    }
    if call_num_bundles(ci) > 0 slp_fail("operand bundles on vectorized calls");
    fty := glob(cf).value_type;
    c := new_inst(.CALL, func_ret(fty), cast(u32) (op_vecs.count + 1));
    inst(c).ty2 = fty;
    for op_vecs set_op(c, cast(u32) it_index, it);
    set_op(c, cast(u32) op_vecs.count, cf);
    v := sgb_insert(c);
    v = slp_propagate_flags_for(te, v);
    inst(v).cc = glob(cf).cc;
    v = slp_final_shuffle(v, te, sty);
    te_set_vv(te, v);
    return v;
}

// the ShuffleVector (alternate opcodes) case of vectorizeTree(E)
slp_vectorize_alt_shuffle :: (te: Te_Id, sty: Type_Id, vec_ty: Type_Id, has_bw: bool, bw: Min_Bw) -> Value_Id {
    e := *slp.entries[te];
    vl0 := e.s.main;
    if !is_alt_shuffle(e.s) slp_fail("REVEC shufflevector nodes");
    opc := te_opcode(te);
    alt_opc := is_alt_opcode(e.s);
    is_cmp := inst_op(vl0) == .ICMP || inst_op(vl0) == .FCMP;
    lhs: Value_Id = NONE; rhs: Value_Id = NONE;
    slp_set_insert_point_after_bundle(te);
    if is_binary_op(opc) || is_cmp {
        lhs = slp_vectorize_operand(te, 0);
        rhs = slp_vectorize_operand(te, 1);
    } else {
        lhs = slp_vectorize_operand(te, 0);
    }
    if lhs != NONE && rhs != NONE && ((is_binary_op(opc) && (vtype(lhs) != vec_ty || vtype(rhs) != vec_ty)) || (is_cmp && vtype(lhs) != vtype(rhs))) {
        cast_ty := vec_ty;
        if is_cmp && vtype(lhs) != vtype(rhs) {
            if type_bits(type_elem(vtype(lhs))) < type_bits(type_elem(vtype(rhs))) cast_ty = vtype(rhs);
            else cast_ty = vtype(lhs);
        }
        if vtype(lhs) != cast_ty lhs = sgb_int_cast(lhs, cast_ty, slp_operand_signedness(te, 0));
        if vtype(rhs) != cast_ty rhs = sgb_int_cast(rhs, cast_ty, slp_operand_signedness(te, 1));
    }
    v0, v1: Value_Id;
    if is_binary_op(opc) {
        v0 = sgb_binop(opc, lhs, rhs);
        v1 = sgb_binop(alt_opc, lhs, rhs);
    } else if is_cmp {
        v0 = sgb_cmp(inst(vl0).pred, lhs, rhs);
        v1 = sgb_cmp(inst(e.s.alt).pred, lhs, rhs);
    } else {
        if is_int_or_int_vector(vtype(lhs)) && is_int_type(sty) {
            src_sz := dl_type_size_bits(type_elem(vtype(lhs)));
            sz := dl_type_size_bits(sty);
            if sz <= src_sz {
                if sz < src_sz lhs = sgb_int_cast(lhs, vec_ty, bw.bits != 0);
                lhs = slp_propagate_flags_for(te, lhs);
                lhs = slp_final_shuffle(lhs, te, sty);
                te_set_vv(te, lhs);
                return lhs;
            }
        }
        v0 = sgb_cast(opc, lhs, vec_ty);
        v1 = sgb_cast(alt_opc, lhs, vec_ty);
    }
    slpg_record(v0);
    slpg_record(v1);
    mask, op_scalars, alt_scalars := te_build_alt_op_shuffle_mask(te);
    slp_propagate_flags_for(te, v0, opc, op_scalars);
    slp_propagate_flags_for(te, v1, alt_opc, alt_scalars);
    v := sgb_shuffle(v0, v1, mask);
    slpg_record(v);
    te_set_vv(te, v);
    return v;
}

// isVectorIntrinsicWithOverloadTypeAtArg(ID, OpdIdx, TTI) (llvm/lib/Analysis/VectorUtils.cpp; X86 has no target
// intrinsic overrides)
slp_overload_type_at_arg :: (id: Intrinsic_Id, idx: s32) -> bool {
    if is_vp_intrinsic(id) fatal("vectorizer: VP intrinsics (%) are not supported yet", iid_name(id));
    n := iid_name(id);
    if n == "llvm.fptosi.sat" || n == "llvm.fptoui.sat" || n == "llvm.lround" || n == "llvm.llround" || n == "llvm.lrint" ||
       n == "llvm.llrint" || n == "llvm.ucmp" || n == "llvm.scmp" || n == "llvm.vector.extract" || n == "llvm.loop.dependence.war.mask"
        return idx == -1 || idx == 0;
    if n == "llvm.modf" || n == "llvm.sincos" || n == "llvm.sincospi" || n == "llvm.is.fpclass" return idx == 0;
    if n == "llvm.powi" || n == "llvm.ldexp" return idx == -1 || idx == 1;
    return idx == -1;
}
// isVectorIntrinsicWithStructReturnOverloadAtField(ID, RetIdx, TTI)
slp_struct_return_overload_at_field :: (id: Intrinsic_Id, ret_idx: s32) -> bool {
    n := iid_name(id);
    if n == "llvm.frexp" return ret_idx == 0 || ret_idx == 1;
    return ret_idx == 0;
}

// CreateUnaryIntrinsic(ID, V) (TargetFolder::FoldIntrinsic for scalars)
sgb_unary_intrinsic :: (id: Intrinsic_Id, v: Value_Id) -> Value_Id {
    f := get_or_insert_intrinsic_declaration(id, .[vtype(v)]);
    fty := glob(f).value_type;
    if is_const(v) {
        if is_vector_type(func_ret(fty)) slp_fail("constant folding of vector-typed intrinsics");
        x := cfo_intrinsic(id, .[v], func_ret(fty));
        if x != NONE return x;
    }
    c := new_inst(.CALL, func_ret(fty), 2);
    inst(c).ty2 = fty;
    set_op(c, 0, v); set_op(c, 1, f);
    return sgb_insert(c);
}

// the ReducedBitcast* / ReducedCmpBitcast cases of vectorizeTree(E)
slp_vectorize_reduced_bitcast :: (te: Te_Id, sty: Type_Id) -> Value_Id {
    code := slp.entries[te].combined_op;
    vf := cast(u64) te_vector_factor(te);
    if code == TE_REDUCED_BITCAST || code == TE_REDUCED_BITCAST_BSWAP {
        if !slpx.has_user_ignore_list fatal("internal: slp: reduced bitcast outside a reduction");
        slp_set_insert_point_after_bundle(te);
        zext := slp_get_operand_entry(te, 0);
        te_set_vv(zext, const_poison(slp_widened_type(vtype(slp.entries[zext].s.main), cast(u64) te_vector_factor(zext))));
        cte := slp_get_operand_entry(te, 1);
        te_set_vv(cte, const_poison(slp_widened_type(vtype(slp.entries[cte].scalars[0]), cast(u64) te_vector_factor(cte))));
        o := slp_vectorize_operand(zext, 0);
        src_sty := vtype(op(slp.entries[zext].s.main, 0));
        src_type := type_int(cast(u32) (dl_type_size_bits(src_sty) * vf));
        o = slp_final_shuffle(o, te, src_sty);
        v := sgb_cast(.BITCAST, o, src_type);
        if code == TE_REDUCED_BITCAST_BSWAP v = sgb_unary_intrinsic(IID_BSWAP, v);
        if src_type != sty v = sgb_int_cast(v, sty, false);
        te_set_vv(te, v);
        return v;
    }
    if code == TE_REDUCED_BITCAST_LOADS || code == TE_REDUCED_BITCAST_BSWAP_LOADS {
        if !slpx.has_user_ignore_list fatal("internal: slp: reduced bitcast outside a reduction");
        zext := slp_get_operand_entry(te, 0);
        load_te := slp_get_operand_entry(zext, 0);
        slp_set_insert_point_after_bundle(load_te);
        te_set_vv(zext, const_poison(slp_widened_type(vtype(slp.entries[zext].s.main), cast(u64) te_vector_factor(zext))));
        cte := slp_get_operand_entry(te, 1);
        te_set_vv(cte, const_poison(slp_widened_type(vtype(slp.entries[cte].scalars[0]), cast(u64) te_vector_factor(cte))));
        te_set_vv(load_te, const_poison(slp_widened_type(vtype(slp.entries[load_te].s.main), cast(u64) te_vector_factor(load_te))));
        li := slp.entries[load_te].s.main;
        src_ty := type_int(cast(u32) (dl_type_size_bits(vtype(op(slp.entries[zext].s.main, 0))) * vf));
        v := sgb_load(src_ty, op(li, 0), inst(li).align);
        if code == TE_REDUCED_BITCAST_BSWAP_LOADS v = sgb_unary_intrinsic(IID_BSWAP, v);
        if src_ty != sty v = sgb_int_cast(v, sty, false);
        te_set_vv(te, v);
        return v;
    }
    if !slpx.has_user_ignore_list fatal("internal: slp: reduced cmp bitcast outside a reduction");
    slp_set_insert_point_after_bundle(te);
    o1 := slp_get_operand_entry(te, 1);
    o2 := slp_get_operand_entry(te, 2);
    te_set_vv(o1, const_poison(slp_widened_type(sty, cast(u64) te_vector_factor(o1))));
    te_set_vv(o2, const_poison(slp_widened_type(sty, cast(u64) te_vector_factor(o2))));
    cmp := slp_vectorize_operand(te, 0);
    dst := type_int(cast(u32) vf);
    v := sgb_cast(.BITCAST, cmp, dst);
    if dst != sty v = sgb_int_cast(v, sty, false);
    te_set_vv(te, v);
    return v;
}
