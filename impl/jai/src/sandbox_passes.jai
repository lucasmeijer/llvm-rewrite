// The SandboxVectorizer's transforming region passes: port of
// llvm/lib/Transforms/Vectorize/SandboxVectorizer/Passes/BottomUpVec.cpp, Passes/LoadStoreVec.cpp,
// Passes/PackReuse.cpp, Legality.cpp (LegalityAnalysis + the LegalityResult classes of Legality.h),
// InstrMaps.cpp / InstrMaps.h (Action, InstrMaps), VecUtils.cpp / VecUtils.h, and the sandboxir::Utils helpers
// (llvm/include/llvm/SandboxIR/Utils.h) they use.
//
// Design (DESIGN.md "SandboxVectorizer"): a LegalityResult subclass is a `kind` tag on the `Sbv_Action` row it
// belongs to (with the reused action, shuffle mask or collect descriptors as its payload); Actions are rows in the
// post-order list `sbv_buv.actions`, their operands are row indices. InstrMaps are two tables keyed by Value_Id.
//
// Address order: BottomUpVec::tryEraseDeadInstrs groups its DenseSet of candidates by block in a DenseMap and
// erases block by block, so when a candidate uses a candidate of another block the outcome depends on the block
// order (fails loudly); LoadStoreVec's SmallPtrSet<, 8> of dead pointers is walked in insertion order up to 8
// elements and in address order beyond (fails loudly when that could matter); PackReuse walks a DenseMap of pack
// groups, which only matters when two groups share instructions (fails loudly).

// ---------------------------------------------------------------- sandboxir::Utils / VecUtils

// Utils::getExpectedType
sbv_expected_type :: (v: Value_Id) -> Type_Id {
    if is_inst(v) {
        o := inst_op(v);
        if o == .STORE return vtype(op(v, 0));
        if o == .RET { if nops(v) == 0 return vtype(v); return vtype(op(v, 0)); }
    }
    return vtype(v);
}
sbv_num_bits_type :: (t: Type_Id) -> u32 { return cast(u32) dl_type_size_bits(t); }
sbv_num_bits :: (v: Value_Id) -> u32 { return sbv_num_bits_type(sbv_expected_type(v)); }
// VecUtils::getElementType
// (scalable vectors: an assert, so release builds take cast<FixedVectorType> on them)
sbv_element_type :: (t: Type_Id) -> Type_Id {
    if is_vector_type(t) return type_elem(t);
    return t;
}
// VecUtils::getNumLanes
// (scalable vectors: an assert, so release builds get 1 from the dyn_cast<FixedVectorType>)
sbv_num_lanes_type :: (t: Type_Id) -> u32 {
    if type_kind(t) == .VECTOR return cast(u32) type_count(t);
    return 1;
}
sbv_num_lanes :: (v: Value_Id) -> u32 { return sbv_num_lanes_type(sbv_expected_type(v)); }
sbv_num_lanes_bndl :: (b: [] Value_Id) -> u32 { n: u32 = 0; for b n += sbv_num_lanes(it); return n; }
// VecUtils::getWideType
sbv_wide_type :: (elem_in: Type_Id, n_in: u32) -> Type_Id {
    elem := elem_in; n := n_in;
    if is_vector_type(elem) { n *= cast(u32) type_count(elem); elem = type_elem(elem); }
    if !is_valid_vector_element_type(elem) fatal("sandbox-vectorizer: a vector of an invalid element type (LLVM asserts)");
    return type_vector(cast(u64) n, elem, false);
}
// VecUtils::getFloorPowerOf2
sbv_floor_pow2 :: (num: u32) -> u32 {
    if num == 0 return 0;
    r: u32 = 1;
    while (r << 1) != 0 && (r << 1) <= num r <<= 1;
    return r;
}
sbv_is_pow2 :: (x: u32) -> bool { return x != 0 && (x & (x - 1)) == 0; }

// Utils::getPointerDiffInBytes: (has value, value); different underlying objects give 0 (`return false`)
sbv_pointer_diff_bytes :: (i0: Value_Id, i1: Value_Id) -> (bool, s64) {
    p0 := load_store_pointer_operand(i0);
    p1 := load_store_pointer_operand(i1);
    if get_underlying_object(p0) != get_underlying_object(p1) return true, 0;
    ok, d := get_pointers_diff(ir.t_i8, p0, ir.t_i8, p1, false, false);
    if !ok return false, 0;
    return true, cast(s64) cast,trunc(s32) d;   // std::optional<int> from optional<int64_t>: truncated
}
// Utils::atLowerAddress
sbv_at_lower_address :: (i0: Value_Id, i1: Value_Id) -> bool {
    ok, d := sbv_pointer_diff_bytes(i0, i1);
    return ok && d > 0;
}
// VecUtils::areConsecutive(I1, I2) / areConsecutive(Bndl)
sbv_are_consecutive_pair :: (i1: Value_Id, i2: Value_Id) -> bool {
    ok, d := sbv_pointer_diff_bytes(i1, i2);
    if !ok return false;
    return d == cast(s64) (sbv_num_bits(i1) / 8);
}
sbv_are_consecutive :: (b: [] Value_Id) -> bool {
    last := b[0];
    for k: 1..b.count - 1 {
        if !sbv_are_consecutive_pair(last, b[k]) return false;
        last = b[k];
    }
    return true;
}
// VecUtils::getLowest(ArrayRef<Value *>, BB)
sbv_lowest_in_block :: (vals: [] Value_Id, bb: Value_Id) -> Value_Id {
    lowest: Value_Id = NONE;
    for vals {
        if !is_inst(it) || inst_block(it) != bb continue;
        if lowest == NONE { lowest = it; continue; }
        if comes_before(lowest, it) lowest = it;
    }
    return lowest;
}
// VecUtils::getLastPHIOrSelf
sbv_last_phi_or_self :: (i_in: Value_Id) -> Value_Id {
    i := i_in;
    last := i;
    while i != NONE && inst_op(i) == .PHI { last = i; i = inst_next(i); }
    return last;
}
// the top of `bb` (after the PHIs) as getInsertPointAfterInstrs / emitUnpacksForExternalUses compute it
sbv_block_top_pt :: (bb: Value_Id) -> Value_Id {
    f := block_first(bb);
    if f == NONE return NONE;
    return inst_next(sbv_last_phi_or_self(f));
}
// getInsertPointAfterInstrs: the position after the lowest of `vals` in bb
sbv_insert_point_after :: (vals: [] Value_Id, bb: Value_Id) -> Value_Id {
    bot := sbv_last_phi_or_self(sbv_lowest_in_block(vals, bb));
    if bot == NONE return sbv_block_top_pt(bb);
    return inst_next(bot);
}
sbv_i32 :: (x: s64) -> Value_Id { return const_int(ir.t_i32, cast(u64) x); }

// VecUtils::unpack
sbv_unpack :: (from_vec: Value_Id, extr_ty: Type_Id, lane: u32, bb: Value_Id, pt: Value_Id) -> Value_Id {
    if !is_vector_type(extr_ty) return sbx_create_extract_element(from_vec, sbv_i32(lane), bb, pt, "Unpack");
    n := type_count(extr_ty);
    mask := NewArray(cast(s64) n, s32,, allocator = temp);
    for k: 0..cast(s64) n - 1 mask[k] = cast(s32) (lane + cast(u32) k);
    return sbx_create_shuffle(from_vec, const_poison(vtype(from_vec)), mask, bb, pt, "Unpack");
}

// LegalityAnalysis::differentBlock / areUnique
sbv_different_block :: (b: [] Value_Id) -> bool {
    bb0 := inst_block(b[0]);
    for k: 1..b.count - 1 if inst_block(b[k]) != bb0 return true;
    return false;
}
sbv_are_unique :: (b: [] Value_Id) -> bool {
    for i: 0..b.count - 1 for j: i + 1..b.count - 1 if b[i] == b[j] return false;
    return true;
}

sbv_in :: (s: [] Value_Id, x: Value_Id) -> bool { for s if it == x return true; return false; }

sbv_copy :: (v: [] Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    array_add(*r, ..v);
    return r;
}

// ---------------------------------------------------------------- Legality + Actions

Sbv_Result_Kind :: enum u8 { PACK; WIDEN; DIAMOND_REUSE; DIAMOND_REUSE_WITH_SHUFFLE; DIAMOND_REUSE_MULTI_INPUT; }
Sbv_Reason :: enum u8 {
    NONE; NOT_INSTRUCTIONS; DIFF_OPCODES; DIFF_TYPES; DIFF_MATH_FLAGS; DIFF_WRAP_FLAGS; DIFF_BBS; REPEATED_INSTRS;
    NOT_CONSECUTIVE; CANT_SCHEDULE; UNIMPLEMENTED; INFEASIBLE; FORCE_PACK_FOR_DEBUGGING;
}
// CollectDescr::ExtractElementDescr: an Action and a lane, or a scalar
Sbv_Descr :: struct { needs_extract: bool; action: s32 = -1; extract_idx: s32; scalar: Value_Id = NONE; }

Sbv_Action :: struct {
    kind: Sbv_Result_Kind;        // the LegalityResult
    reason: Sbv_Reason;           // Pack's reason
    reuse: s32 = -1;              // DiamondReuse / DiamondReuseWithShuffle: the vector's Action
    mask: [..] s32;               // DiamondReuseWithShuffle
    descrs: [..] Sbv_Descr;       // DiamondReuseMultiInput
    bndl: [..] Value_Id;
    user_bndl: [..] Value_Id;
    depth: u32;
    operands: [..] s32;
    vec: Value_Id = NONE;
}

sbv_buv: struct {
    actions: [..] Sbv_Action;               // ActionsVector (post order)
    dead: [..] Value_Id;                    // DeadInstrCandidates (a DenseSet)
    orig_to_vec: Table(Value_Id, s32);      // InstrMaps::OrigToVectorMap
    orig_lane: Table(u64, u32);             // InstrMaps::VectorToOrigLaneMap
    change: bool;
    debug_bndl_cnt: u64;
}

sbv_imaps_clear :: () {
    sbv_buv.orig_to_vec = .{}; sbv_buv.orig_to_vec.allocator = temp;
    sbv_buv.orig_lane = .{}; sbv_buv.orig_lane.allocator = temp;
}
sbv_lane_key :: (a: s32, v: Value_Id) -> u64 { return ((cast(u64) cast(u32) a) << 32) | cast(u64) v; }
sbv_vector_for_orig :: (v: Value_Id) -> s32 {
    found, a := table_find(*sbv_buv.orig_to_vec, v);
    return ifx found then a else -1;
}
// InstrMaps::registerVector
sbv_register_vector :: (origs: [] Value_Id, a: s32) {
    lane: u32 = 0;
    for origs {
        found := table_find_pointer(*sbv_buv.orig_to_vec, it);
        if !found table_set(*sbv_buv.orig_to_vec, it, a);
        table_set(*sbv_buv.orig_lane, sbv_lane_key(a, it), lane);
        lane += sbv_num_lanes(it);
    }
}

// LegalityAnalysis::notVectorizableBasedOnOpcodesAndTypes
sbv_not_vectorizable :: (b: [] Value_Id) -> Sbv_Reason {
    i0 := b[0];
    opc := inst_op(i0);
    for k: 1..b.count - 1 if inst_op(b[k]) != opc return .DIFF_OPCODES;
    elm0 := sbv_element_type(sbv_expected_type(i0));
    for k: 1..b.count - 1 if sbv_element_type(sbv_expected_type(b[k])) != elm0 return .DIFF_TYPES;
    if is_fp_math_inst(i0) {
        f0 := inst_fmf(i0);
        for k: 1..b.count - 1 if inst_fmf(b[k]) != f0 return .DIFF_MATH_FLAGS;
    }
    if is_overflowing_binop(i0) || opc == .TRUNC {
        nuw0 := has_nuw(i0); nsw0 := has_nsw(i0);
        for k: 1..b.count - 1 if has_nuw(b[k]) != nuw0 || has_nsw(b[k]) != nsw0 return .DIFF_WRAP_FLAGS;
    }
    if opc == {
        case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
        case .FPEXT; #through; case .PTRTOADDR; #through; case .PTRTOINT; #through; case .INTTOPTR; #through;
        case .SITOFP; #through; case .UITOFP; #through; case .TRUNC; #through; case .FPTRUNC; #through;
        case .BITCAST;
            from0 := sbv_expected_type(op(i0, 0));
            for k: 1..b.count - 1 if sbv_expected_type(op(b[k], 0)) != from0 return .DIFF_TYPES;
            return .NONE;
        case .FCMP; #through;
        case .ICMP;
            p0 := inst_pred(i0);
            t0 := vtype(op(i0, 0));
            for b if inst_pred(it) != p0 || vtype(op(it, 0)) != t0 return .DIFF_OPCODES;
            return .NONE;
        case .SELECT;
            if sbv_num_lanes(op(i0, 0)) != sbv_num_lanes(i0) return .UNIMPLEMENTED;
            return .NONE;
        case .FNEG; #through; case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through;
        case .MUL; #through; case .FMUL; #through; case .FREM; #through; case .UDIV; #through; case .SDIV; #through;
        case .FDIV; #through; case .UREM; #through; case .SREM; #through; case .SHL; #through; case .LSHR; #through;
        case .ASHR; #through; case .AND; #through; case .OR; #through; case .XOR;
            return .NONE;
        case .LOAD; #through;
        case .STORE;
            if sbv_are_consecutive(b) return .NONE;
            return .NOT_CONSECUTIVE;
        case .PHI; return .UNIMPLEMENTED;
        case .INDIRECTBR; #through; case .USEROP1; #through; case .USEROP2;
            return .UNIMPLEMENTED;   // sandboxir::OpaqueInst
        case .BR; #through; case .CONDBR; #through; case .RET; #through; case .ADDRSPACECAST; #through;
        case .INSERTELEMENT; #through; case .INSERTVALUE; #through; case .EXTRACTELEMENT; #through;
        case .EXTRACTVALUE; #through; case .SHUFFLEVECTOR; #through; case .CALL; #through; case .GEP; #through;
        case .SWITCH;
            return .UNIMPLEMENTED;
        case .VAARG; #through; case .FREEZE; #through; case .FENCE; #through; case .INVOKE; #through;
        case .CALLBR; #through; case .LANDINGPAD; #through; case .CATCHPAD; #through; case .CLEANUPPAD; #through;
        case .CATCHRET; #through; case .CLEANUPRET; #through; case .RESUME; #through; case .CATCHSWITCH; #through;
        case .ATOMICRMW; #through; case .CMPXCHG; #through; case .ALLOCA; #through; case .UNREACHABLE;
            return .INFEASIBLE;
    }
    return .NONE;
}

// LegalityAnalysis::getHowToCollectValues
sbv_how_to_collect :: (b: [] Value_Id) -> [..] Sbv_Descr {
    out: [..] Sbv_Descr; out.allocator = temp;
    for v: b {
        a := sbv_vector_for_orig(v);
        if a >= 0 {
            found, lane := table_find(*sbv_buv.orig_lane, sbv_lane_key(a, v));
            n := sbv_num_lanes(v);
            for ln: 0..cast(s64) n - 1 {
                d: Sbv_Descr; d.needs_extract = true; d.action = a;
                d.extract_idx = ifx found then cast(s32) lane + cast(s32) ln else -1;
                array_add(*out, d);
            }
        } else {
            d: Sbv_Descr; d.scalar = v;
            array_add(*out, d);
        }
    }
    return out;
}

// LegalityAnalysis::canVectorize: fills a.kind / a.reason / the payload
sbv_can_vectorize :: (a: *Sbv_Action) {
    b := a.bndl;
    for b if !is_inst(it) { a.kind = .PACK; a.reason = .NOT_INSTRUCTIONS; return; }
    if sbv_different_block(b) { a.kind = .PACK; a.reason = .DIFF_BBS; return; }
    if !sbv_are_unique(b) { a.kind = .PACK; a.reason = .REPEATED_INSTRS; return; }
    descrs := sbv_how_to_collect(b);
    has_vec := false;
    for descrs if it.needs_extract { has_vec = true; break; }
    if has_vec {
        // CollectDescr::getSingleInput
        single := descrs[0].needs_extract;
        if single for descrs if !it.needs_extract || it.action != descrs[0].action { single = false; break; }
        if single {
            identity := true;
            for descrs if it.extract_idx != cast(s32) it_index { identity = false; break; }
            if identity { a.kind = .DIAMOND_REUSE; a.reuse = descrs[0].action; return; }
            a.kind = .DIAMOND_REUSE_WITH_SHUFFLE; a.reuse = descrs[0].action;
            a.mask.allocator = temp;
            for descrs array_add(*a.mask, it.extract_idx);
            return;
        }
        a.kind = .DIAMOND_REUSE_MULTI_INPUT;
        a.descrs = descrs;
        return;
    }
    r := sbv_not_vectorizable(b);
    if r != .NONE { a.kind = .PACK; a.reason = r; return; }
    if !ssch_try_schedule(b) { a.kind = .PACK; a.reason = .CANT_SCHEDULE; return; }
    a.kind = .WIDEN;
}

// ---------------------------------------------------------------- BottomUpVec

sbv_operand_bundle :: (b: [] Value_Id, k: u32) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    for b array_add(*r, op(it, k));
    return r;
}

// BottomUpVec::vectorizeRec
sbv_vectorize_rec :: (bndl: [] Value_Id, user_bndl: [] Value_Id, depth: u32) -> s32 {
    stop_for_debug := sbv_buv.debug_bndl_cnt >= sbv_cl.stop_bndl && sbv_cl.stop_bndl != SBV_DISABLED;
    sbv_buv.debug_bndl_cnt += 1;
    a: Sbv_Action;
    a.bndl = sbv_copy(bndl);
    a.user_bndl = sbv_copy(user_bndl);
    a.depth = depth;
    a.operands.allocator = temp;
    if stop_for_debug { a.kind = .PACK; a.reason = .FORCE_PACK_FOR_DEBUGGING; }
    else sbv_can_vectorize(*a);
    if a.kind == .WIDEN {
        i0 := bndl[0];
        o := inst_op(i0);
        if o == .LOAD {
        } else if o == .STORE {
            array_add(*a.operands, sbv_vectorize_rec(sbv_operand_bundle(bndl, 0), bndl, depth + 1));
        } else {
            n := nops(i0);
            for k: 0..n - 1 array_add(*a.operands, sbv_vectorize_rec(sbv_operand_bundle(bndl, k), bndl, depth + 1));
        }
        sbv_register_vector(bndl, cast(s32) sbv_buv.actions.count);
    }
    array_add(*sbv_buv.actions, a);
    return cast(s32) sbv_buv.actions.count - 1;
}

// BottomUpVec::createVectorInstr
sbv_create_vector_instr :: (bndl: [] Value_Id, operands: [] Value_Id) -> Value_Id {
    i0 := bndl[0];
    scalar_ty := sbv_element_type(sbv_expected_type(i0));
    vec_ty := sbv_wide_type(scalar_ty, sbv_num_lanes_bndl(bndl));
    bb := inst_block(i0);
    pt := sbv_insert_point_after(bndl, bb);
    opc := inst_op(i0);
    if opc == {
        case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
        case .FPEXT; #through; case .PTRTOINT; #through; case .INTTOPTR; #through; case .SITOFP; #through;
        case .UITOFP; #through; case .TRUNC; #through; case .FPTRUNC; #through; case .BITCAST;
            return sbx_create_cast(vec_ty, opc, operands[0], bb, pt, "VCast");
        case .FCMP; #through;
        case .ICMP;
            return sbx_create_cmp(opc == .FCMP, inst_pred(i0), operands[0], operands[1], bb, pt, "VCmp");
        case .SELECT;
            return sbx_create_select(operands[0], operands[1], operands[2], bb, pt, "Vec");
        case .FNEG;
            return sbx_create_unop_copied_flags(.FNEG, operands[0], i0, bb, pt, "Vec");
        case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through; case .MUL; #through;
        case .FMUL; #through; case .UDIV; #through; case .SDIV; #through; case .FDIV; #through; case .UREM; #through;
        case .SREM; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through;
        case .AND; #through; case .OR; #through; case .XOR;
            return sbx_create_binop_copied_flags(opc, operands[0], operands[1], i0, bb, pt, "Vec");
        case .LOAD;
            return sbx_create_load(vec_ty, op(i0, 0), inst(i0).align, bb, pt, "VecL");
        case .STORE;
            return sbx_create_store(operands[0], operands[1], inst(i0).align, bb, pt);
    }
    fatal("sandbox-vectorizer: widening '%' is unimplemented in LLVM (llvm_unreachable)", opcode_name(opc));
    return NONE;
}

// BottomUpVec::createShuffle
sbv_create_shuffle :: (vec: Value_Id, mask: [] s32, user_bb: Value_Id) -> Value_Id {
    one: [1] Value_Id; one[0] = vec;
    pt := sbv_insert_point_after(one, user_bb);
    return sbx_create_shuffle(vec, vec, mask, user_bb, pt, "VShuf");
}

// BottomUpVec::createPack
sbv_create_pack :: (to_pack: [] Value_Id, user_bb: Value_Id) -> Value_Id {
    pt := sbv_insert_point_after(to_pack, user_bb);
    scalar_ty := sbv_element_type(sbv_expected_type(to_pack[0]));
    vec_ty := sbv_wide_type(scalar_ty, sbv_num_lanes_bndl(to_pack));
    last := const_poison(vec_ty);
    insert_idx := 0;
    for elm: to_pack {
        et := vtype(elm);
        if is_vector_type(et) {
            n := cast(s64) sbv_num_lanes_type(et);
            for lane: 0..n - 1 {
                ex := sbx_create_extract_element(elm, sbv_i32(lane), user_bb, pt, "VPack");
                if is_inst(ex) pt = inst_next(ex);
                ins := sbx_create_insert_element(last, ex, sbv_i32(insert_idx), user_bb, pt, "VPack");
                insert_idx += 1;
                last = ins;
                if is_inst(ins) pt = inst_next(ins);
            }
        } else {
            last = sbx_create_insert_element(last, elm, sbv_i32(insert_idx), user_bb, pt, "Pack");
            insert_idx += 1;
            if is_inst(last) pt = inst_next(last);
        }
    }
    return last;
}

sbv_dead_insert :: (i: Value_Id) {
    for sbv_buv.dead if it == i return;
    array_add(*sbv_buv.dead, i);
}
// BottomUpVec::collectPotentiallyDeadInstrs
sbv_collect_potentially_dead :: (b: [] Value_Id) {
    for b sbv_dead_insert(it);
    o := inst_op(b[0]);
    if o == .LOAD || o == .STORE {
        for k: 1..b.count - 1 {
            p := load_store_pointer_operand(b[k]);
            if is_inst(p) sbv_dead_insert(p);
        }
    }
}

// BottomUpVec::tryEraseDeadInstrs
sbv_try_erase_dead :: () {
    blocks: [..] Value_Id; blocks.allocator = temp;
    for sbv_buv.dead {
        bb := inst_block(it);
        found := false;
        for blocks if it == bb { found = true; break; }
        if !found array_add(*blocks, bb);
    }
    // sorted groups, one per block
    groups: [..] [..] Value_Id; groups.allocator = temp;
    for bb: blocks {
        group: [..] Value_Id; group.allocator = temp;
        for sbv_buv.dead if inst_block(it) == bb array_add(*group, it);
        quick_sort(group, (a: Value_Id, b: Value_Id) -> s64 {
            if a == b return 0;
            return ifx comes_before(a, b) then -1 else 1;
        });
        array_add(*groups, group);
    }
    if blocks.count > 1 sbv_check_dead_block_order(groups);
    for group: groups {
        k := group.count - 1;
        while k >= 0 {
            i := group[k];
            if !has_uses(i) sbx_erase(i);
            k -= 1;
        }
    }
    sbv_buv.dead.count = 0;
}

// The blocks of tryEraseDeadInstrs are visited in DenseMap (block address) order. Erasing a candidate can make a
// candidate of another block dead, so dry-run every block order (up to 5 blocks) and fail loudly unless they all
// erase the same instructions.
sbv_check_dead_block_order :: (groups: [] [..] Value_Id) {
    cross := false;
    for c: sbv_buv.dead for k: 0..cast(s64) nops(c) - 1 {
        o := op(c, cast(u32) k);
        if is_inst(o) && inst_block(o) != inst_block(c) && sbv_in(sbv_buv.dead, o) cross = true;
    }
    if !cross return;
    if groups.count > 5 fatal("sandbox-vectorizer: dead instructions in many blocks depend on each other (LLVM erases them in block address order)");
    n := groups.count;
    perm: [5] s64;
    for 0..n - 1 perm[it] = it;
    first: [..] bool; first.allocator = temp;
    have_first := false;
    while true {
        // dry run in the order `perm`
        uses: Table(Value_Id, s64); uses.allocator = temp;
        for sbv_buv.dead table_set(*uses, it, num_uses(it));
        erased: [..] bool; erased.allocator = temp;
        for sbv_buv.dead array_add(*erased, false);
        for g: 0..n - 1 {
            group := groups[perm[g]];
            k := group.count - 1;
            while k >= 0 {
                i := group[k];
                _, cnt := table_find(*uses, i);
                if cnt == 0 {
                    for x: sbv_buv.dead if x == i erased[it_index] = true;
                    for e: 0..cast(s64) nops(i) - 1 {
                        o := op(i, cast(u32) e);
                        p := table_find_pointer(*uses, o);
                        if p p.* -= 1;
                    }
                }
                k -= 1;
            }
        }
        if !have_first { first = erased; have_first = true; }
        else for erased if it != first[it_index]
            fatal("sandbox-vectorizer: dead instructions in two blocks depend on each other (LLVM erases them in block address order; its output varies from run to run)");
        // next permutation
        x := n - 2;
        while x >= 0 && perm[x] >= perm[x + 1] x -= 1;
        if x < 0 break;
        y := n - 1;
        while perm[y] <= perm[x] y -= 1;
        perm[x], perm[y] = perm[y], perm[x];
        l := x + 1; r := n - 1;
        while l < r { perm[l], perm[r] = perm[r], perm[l]; l += 1; r -= 1; }
    }
}

// BottomUpVec::emitUnpacksForExternalUses
sbv_emit_unpacks :: (bndl: [] Value_Id, vec: Value_Id) {
    bb: Value_Id; pt: Value_Id;
    if is_inst(vec) { bb = inst_block(vec); pt = inst_next(vec); }
    else { bb = inst_block(bndl[0]); pt = sbv_block_top_pt(bb); }
    lane: u32 = 0;
    for elm: bndl {
        // for (User *U : Elm->users()), with the RAUW in the body: the walk continues from the current use, which
        // the RAUW moved to the unpack's use list
        u := ir.v_first_use[elm];
        while u != NONE {
            user := ir.u_user[u];
            if user != NONE && sbv_vector_for_orig(user) >= 0 { u = ir.u_next[u]; continue; }
            unpack := sbv_unpack(vec, vtype(elm), lane, bb, pt);
            sbx_rauw(elm, unpack);
            // a folded (constant) unpack: the rest of the walk is over the constant's other users and only folds
            // more unpacks and replaces the now unused `elm` (no IR changes)
            if !is_inst(unpack) break;
            u = ir.u_next[u];
        }
        lane += sbv_num_lanes(elm);
    }
}

// BottomUpVec::emitVectors
sbv_emit_vectors :: () -> Value_Id {
    new_vec: Value_Id = NONE;
    for ai: 0..sbv_buv.actions.count - 1 {
        a := *sbv_buv.actions[ai];
        bndl := a.bndl;
        user_bb := ifx a.user_bndl.count then inst_block(a.user_bndl[0]) else inst_block(bndl[0]);
        if a.kind == {
            case .WIDEN;
                i0 := bndl[0];
                vops: [..] Value_Id; vops.allocator = temp;
                o := inst_op(i0);
                if o == .LOAD array_add(*vops, op(i0, 0));
                else if o == .STORE {
                    array_add(*vops, sbv_buv.actions[a.operands[0]].vec);
                    array_add(*vops, op(i0, 1));
                } else {
                    for a.operands array_add(*vops, sbv_buv.actions[it].vec);
                }
                for vops if it == NONE fatal("internal: sandbox-vectorizer: an operand action produced no vector");
                new_vec = sbv_create_vector_instr(bndl, vops);
                if new_vec != NONE sbv_collect_potentially_dead(bndl);
                sbv_emit_unpacks(bndl, new_vec);
            case .DIAMOND_REUSE;
                new_vec = sbv_buv.actions[a.reuse].vec;
                if new_vec != NONE {
                    want := sbv_wide_type(sbv_element_type(sbv_expected_type(bndl[0])), sbv_num_lanes_bndl(bndl));
                    if vtype(new_vec) != want fatal("sandbox-vectorizer: a diamond reuse of a vector of another type (LLVM emits broken IR)");
                }
            case .DIAMOND_REUSE_WITH_SHUFFLE;
                v := sbv_buv.actions[a.reuse].vec;
                new_vec = sbv_create_shuffle(v, a.mask, user_bb);
                if vtype(new_vec) != vtype(v) fatal("sandbox-vectorizer: a reuse shuffle changes the vector type (LLVM asserts)");
            case .DIAMOND_REUSE_MULTI_INPUT;
                res_ty := sbv_wide_type(vtype(bndl[0]), cast(u32) bndl.count);
                descr_instrs: [..] Value_Id; descr_instrs.allocator = temp;
                for d: a.descrs {
                    v := ifx d.needs_extract then sbv_buv.actions[d.action].vec else d.scalar;
                    if is_inst(v) array_add(*descr_instrs, v);
                }
                pt := sbv_insert_point_after(descr_instrs, user_bb);
                last := const_poison(res_ty);
                lane := 0;
                for d: a.descrs {
                    to_insert: Value_Id;
                    if d.needs_extract {
                        vop := sbv_buv.actions[d.action].vec;
                        to_insert = sbx_create_extract_element(vop, const_int(ir.t_i32, cast(u64) d.extract_idx), user_bb, pt, "VExt");
                    } else to_insert = d.scalar;
                    n := cast(s64) sbv_num_lanes(to_insert);
                    if n == 1 {
                        last = sbx_create_insert_element(last, to_insert, sbv_i32(lane), user_bb, pt, "VIns");
                    } else {
                        for ln: 0..n - 1 {
                            ex := sbx_create_extract_element(to_insert, sbv_i32(ln), user_bb, pt, "VExt");
                            last = sbx_create_insert_element(last, ex, sbv_i32(lane + ln), user_bb, pt, "VIns");
                        }
                    }
                    lane += n;
                }
                new_vec = last;
            case .PACK;
                if a.depth == 0 return NONE;
                new_vec = sbv_create_pack(bndl, user_bb);
        }
        if new_vec != NONE {
            sbv_buv.change = true;
            sbv_buv.actions[ai].vec = new_vec;
        }
    }
    return new_vec;
}

// BottomUpVec::runOnRegion + tryVectorize
sbv_bottom_up_vec :: (p: *Sbv_Pass, r: s32) -> bool {
    aux := sbv_regions[r].aux;
    if aux.count == 0 fatal("sandbox-vectorizer: bottom-up-vec on a region without a seed slice (LLVM reads past an empty Aux)");
    for aux if it == NONE fatal("sandbox-vectorizer: bottom-up-vec on a region whose Aux has a gap (LLVM dereferences null)");
    seeds := sbv_copy(aux);
    sbv_imaps_clear();
    ssch_new(sbv_aar);
    defer ssch_delete();
    // tryVectorize
    sbv_buv.change = false;
    cnt := p.invocation_cnt;
    p.invocation_cnt += 1;
    if cnt >= sbv_cl.stop_at && sbv_cl.stop_at != SBV_DISABLED return false;
    sbv_temp_array(*sbv_buv.dead);
    ssch_clear();
    sbv_imaps_clear();
    sbv_temp_array(*sbv_buv.actions);
    sbv_buv.debug_bndl_cnt = 0;
    sbv_vectorize_rec(seeds, .[], 0);
    sbv_emit_vectors();
    sbv_try_erase_dead();
    return sbv_buv.change;
}

// ---------------------------------------------------------------- LoadStoreVec

// VecUtils::getCombinedVectorTypeFor
sbv_combined_vector_type :: (b: [] Value_Id) -> Type_Id {
    total: u32 = 0;
    min_bits: u32 = 0xFFFF_FFFF;
    min_ty: Type_Id = NONE;
    for b {
        et := sbv_element_type(sbv_expected_type(it));
        bits := sbv_num_bits_type(et);
        total += bits * sbv_num_lanes(it);
        if bits < min_bits { min_bits = bits; min_ty = et; }
    }
    return sbv_wide_type(min_ty, total / min_bits);
}

// LoadStoreVec::canVectorize
sbv_lsv_can_vectorize :: (b: [] Value_Id) -> bool {
    if sbv_different_block(b) return false;
    if !sbv_are_unique(b) return false;
    return ssch_try_schedule(b);
}

// LoadStoreVec::tryEraseDeadInstrs
sbv_lsv_erase_dead :: (stores: [] Value_Id, operands: [] Value_Id) {
    cands: [..] Value_Id; cands.allocator = temp;   // SmallPtrSet<Instruction *, 8>
    add :: (c: *[..] Value_Id, i: Value_Id) { for c.* if it == i return; array_add(c, i); }
    for s: stores {
        p := op(s, 1);
        if is_inst(p) add(*cands, p);
        sbx_erase(s);
    }
    for o: operands {
        if is_inst(o) && inst_op(o) == .LOAD {
            p := op(o, 0);
            if is_inst(p) add(*cands, p);
            sbx_erase(o);
        }
    }
    if cands.count > 8 {
        // walked in address order: fine when the candidates dead from the start are all that any order can erase
        uses: Table(Value_Id, s64); uses.allocator = temp;
        for cands table_set(*uses, it, num_uses(it));
        erased: [..] bool; erased.allocator = temp;
        for cands array_add(*erased, false);
        initially := 0;
        for cands if num_uses(it) == 0 initially += 1;
        total := 0;
        progress := true;
        while progress {
            progress = false;
            for c, ci: cands {
                if erased[ci] continue;
                _, n := table_find(*uses, c);
                if n != 0 continue;
                erased[ci] = true; total += 1; progress = true;
                for k: 0..cast(s64) nops(c) - 1 { p := table_find_pointer(*uses, op(c, cast(u32) k)); if p p.* -= 1; }
            }
        }
        if total != initially
            fatal("sandbox-vectorizer: more than 8 dead pointer candidates that depend on each other (LLVM walks them in address order)");
    }
    for cands if !has_uses(it) sbx_erase(it);
}


// ConstantVector::get(Constants): the element type is the first constant's. With mixed element types the
// zero / undef / splat checks (which compare constants by identity) fail, so only the ConstantDataVector path is
// left: the values are truncated to the first element's width.
sbv_constant_vector :: (consts: [] Value_Id) -> Value_Id {
    et := vtype(consts[0]);
    if !is_valid_vector_element_type(et) fatal("sandbox-vectorizer: a constant vector of an invalid element type (LLVM asserts)");
    t := type_vector(cast(u64) consts.count, et, false);
    same := true;
    for consts if vtype(it) != et { same = false; break; }
    if same return cf_vector(t, consts);
    c0 := consts[0];
    if !data_compatible_elt(et) || (vkind(c0) != .C_INT && vkind(c0) != .C_FP)
        fatal("sandbox-vectorizer: a constant vector of mixed element types that LLVM cannot build (an invalid ConstantVector)");
    bits := dl_type_size_bits(et);
    mask: u64 = ifx bits >= 64 then 0xFFFF_FFFF_FFFF_FFFF else ((cast(u64) 1) << bits) - 1;
    words := NewArray(consts.count, u64,, allocator = temp);
    all_zero := true;
    for c: consts {
        if vkind(c) != vkind(c0) fatal("sandbox-vectorizer: a constant vector of mixed element types that LLVM cannot build (an invalid ConstantVector)");
        w: u64;
        if vkind(c) == .C_INT {
            if type_int_width(vtype(c)) > 64 fatal("sandbox-vectorizer: a constant wider than 64 bits in a mixed constant vector (LLVM asserts)");
            w = const_int_zext(c);
        } else {
            fw := const_fp_value(c);
            w = fw[0];
            for k: 1..fw.count - 1 if fw[k] != 0 w = 0xFFFF_FFFF_FFFF_FFFF;   // APInt::getLimitedValue
        }
        words[it_index] = w & mask;
        if words[it_index] != 0 all_zero = false;
    }
    if all_zero return const_null_value(t);   // ConstantDataSequential::getImpl: all zero is a ConstantAggregateZero
    return const_data(t, words);
}

// LoadStoreVec::runOnRegion
sbv_load_store_vec :: (p: *Sbv_Pass, r: s32) -> bool {
    bndl := sbv_copy(sbv_regions[r].aux);
    if bndl.count < 2 return false;
    for bndl if it == NONE fatal("sandbox-vectorizer: load-store-vec on a region whose Aux has a gap (LLVM dereferences null)");
    ssch_new(sbv_aar);
    defer ssch_delete();
    for bndl if inst_op(it) != .STORE fatal("sandbox-vectorizer: load-store-vec on a non-store seed (LLVM casts it to StoreInst)");
    if !sbv_are_consecutive(bndl) return false;
    if !sbv_lsv_can_vectorize(bndl) return false;
    rg := *sbv_regions[r];
    cost_before := cost_sub(rg.after_cost, rg.before_cost);
    operands: [..] Value_Id; operands.allocator = temp;
    for bndl array_add(*operands, op(it, 0));
    bb := inst_block(bndl[0]);
    all_loads := true;
    for operands {
        if !is_inst(it) || inst_op(it) != .LOAD || inst_block(it) != bb || num_uses(it) >= 2 { all_loads = false; break; }
    }
    all_constants := true;
    for operands if !is_const(it) { all_constants = false; break; }
    if !all_loads && !all_constants return false;
    sbx_save();
    vec_op: Value_Id = NONE;
    if all_loads {
        if !sbv_are_consecutive(operands) { sbx_accept(); return false; }
        if !sbv_lsv_can_vectorize(operands) { sbx_accept(); return false; }
        ty := sbv_combined_vector_type(bndl);
        ld_ptr := op(operands[0], 0);
        lowest := sbv_lowest(operands);
        vec_op = sbx_create_load(ty, ld_ptr, 1, inst_block(lowest), inst_next(lowest), "VecIinitL");
    } else {
        consts: [..] Value_Id; consts.allocator = temp;
        for c: operands {
            t := vtype(c);
            k := vkind(c);
            if k == .C_ARRAY || k == .C_STRUCT || k == .C_VECTOR {
                for e: 0..cast(s64) nops(c) - 1 array_add(*consts, op(c, cast(u32) e));
            } else if k == .C_DATA {
                for e: 0..cast(s64) type_count(t) - 1 array_add(*consts, cf_elt(c, cast(u32) e));
            } else if k == .C_ZERO {
                if type_kind(t) == .STRUCT fatal("sandbox-vectorizer: storing a zero struct constant (LLVM asserts)");
                for e: 0..cast(s64) type_count(t) - 1 array_add(*consts, const_null_value(type_elem(t)));
            } else if (k == .C_INT || k == .C_FP) && is_vector_type(t) {
                e0 := cf_elt(c, 0);
                for e: 0..cast(s64) type_count(t) - 1 array_add(*consts, e0);
            } else {
                array_add(*consts, c);
            }
        }
        vec_op = sbv_constant_vector(consts);
    }
    st_ptr := op(bndl[0], 1);
    lowest := sbv_lowest(bndl);
    sbx_create_store(vec_op, st_ptr, 1, inst_block(lowest), inst_next(lowest));
    sbv_lsv_erase_dead(bndl, operands);
    rg = *sbv_regions[r];
    cost_after := cost_sub(rg.after_cost, rg.before_cost);
    gain := cost_sub(cost_after, cost_before);
    if !cost_valid(gain) || gain > cast(Cost) sbv_cl.cost_threshold {
        sbx_revert();
        return false;
    }
    sbx_accept();
    return true;
}

// ---------------------------------------------------------------- PackReuse

// VecUtils::matchPack: the inserts bottom-up and the packed operands, or false
sbv_match_pack :: (i: Value_Id, instrs: *[..] Value_Id, operands: *[..] Value_Id) -> bool {
    if inst_op(i) != .INSERTELEMENT return false;
    bb0 := inst_block(i);
    n := cast(s64) sbv_num_lanes(i);
    instrs.count = 0;
    operands.count = 0;
    for 0..n - 1 array_add(operands, NONE);
    ins := i;
    lane := n - 1;
    while lane >= 0 {
        if ins == NONE return false;
        if inst_block(ins) != bb0 return false;
        lc := op(ins, 2);
        if vkind(lc) != .C_INT || is_vector_type(vtype(lc)) || const_int_sext(lc) != lane return false;
        array_add(instrs, ins);
        operands.*[lane] = op(ins, 1);
        o := op(ins, 0);
        if lane == 0 {
            if vkind(o) != .C_POISON return false;
        } else {
            ins = ifx is_inst(o) && inst_op(o) == .INSERTELEMENT then o else NONE;
        }
        lane -= 1;
    }
    return true;
}

// PackReuse::runOnRegion
sbv_pack_reuse :: (p: *Sbv_Pass, r: s32) -> bool {
    if sbv_regions[r].insts.count == 0 return p.pack_reuse_change;
    Group :: struct { bb: Value_Id; operands: [..] Value_Id; packs: [..] [..] Value_Id; }
    groups: [..] Group; groups.allocator = temp;
    all_instrs: Table(Value_Id, s32); all_instrs.allocator = temp;   // instruction -> its group (sharing check)
    shared := false;
    insts := sbv_copy(sbv_regions[r].insts);
    for i: insts {
        pi: [..] Value_Id; pi.allocator = temp;
        po: [..] Value_Id; po.allocator = temp;
        if !sbv_match_pack(i, *pi, *po) continue;
        bb := inst_block(pi[0]);
        g := -1;
        for groups {
            if it.bb != bb || it.operands.count != po.count continue;
            same := true;
            for k: 0..po.count - 1 if it.operands[k] != po[k] { same = false; break; }
            if same { g = it_index; break; }
        }
        if g < 0 {
            ng: Group; ng.bb = bb; ng.operands = po; ng.packs.allocator = temp;
            array_add(*groups, ng);
            g = groups.count - 1;
        }
        array_add(*groups[g].packs, pi);
        for pi {
            found, og := table_find(*all_instrs, it);
            if found && og != g shared = true;
            table_set(*all_instrs, it, cast(s32) g);
        }
    }
    if shared {
        n := 0;
        for groups if it.packs.count > 1 n += 1;
        if n > 0 fatal("sandbox-vectorizer: pack-reuse groups share instructions (LLVM visits the groups in address order)");
    }
    for * grp: groups {
        packs := grp.packs;
        if packs.count <= 1 continue;
        quick_sort(packs, (a: [..] Value_Id, b: [..] Value_Id) -> s64 {
            if a[0] == b[0] return 0;
            return ifx comes_before(a[0], b[0]) then -1 else 1;
        });
        top_most := packs[0][0];
        for k: 1..packs.count - 1 {
            sbx_rauw(packs[k][0], top_most);
            for packs[k] sbx_erase(it);
        }
        p.pack_reuse_change = true;
    }
    return p.pack_reuse_change;
}
