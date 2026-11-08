// Loop metadata and profile helpers.
// Ports from llvm/lib/Transforms/Utils/LoopUtils.cpp (addStringMetadataToLoop, makeFollowupLoopID,
// hasDisableAllTransformsHint, hasUnrollTransformation, hasUnrollAndJamTransformation, getExpectedExitLoopLatchBranch,
// estimateLoopTripCount, getLoopEstimatedTripCount, setLoopEstimatedTripCount, getLoopProbability,
// setLoopProbability, getBranchProbability, setBranchProbability), llvm/lib/Analysis/LoopInfo.cpp
// (Loop::isSafeToClone, setLoopAlreadyUnrolled, addStringLoopAttribute, getOptionalBoolLoopAttribute,
// getBooleanLoopAttribute, getOptionalIntLoopAttribute, getLoopConvergenceHeart, makePostTransformationMetadata)
// and llvm/include/llvm/Support/BranchProbability.h + lib/Support/BranchProbability.cpp (`Bprob`).

// ---------------------------------------------------------------- loop attributes (LoopInfo.cpp)

// getOptionalBoolLoopAttribute: (present, value)
li_optional_bool_loop_attribute :: (li: *Loop_Info, l: Loop_Id, name: string) -> (bool, bool) {
    md := find_option_md_for_loop_id(li_loop_id(li, l), name);
    if md == NONE return false, false;
    n := md_nops(md);
    if n == 1 return true, true;
    if n == 2 {
        o := md_op(md, 1);
        if o != NONE && ir.mds[o].kind == .VALUE {
            v := ir.mds[o].value;
            if vkind(v) == .C_INT return true, !ap_is_zero(const_ap(v));
        }
        return true, true;
    }
    fatal("internal: unexpected number of options in loop metadata");
    return false, false;
}
li_get_boolean_loop_attribute :: (li: *Loop_Info, l: Loop_Id, name: string) -> bool {
    present, v := li_optional_bool_loop_attribute(li, l, name);
    return present && v;
}
// getOptionalIntLoopAttribute: (present, value) (sign-extended)
li_optional_int_loop_attribute :: (li: *Loop_Info, l: Loop_Id, name: string) -> (bool, s64) {
    md := find_option_md_for_loop_id(li_loop_id(li, l), name);
    if md == NONE return false, 0;
    n := md_nops(md);
    if n == 1 return false, 0;
    if n != 2 fatal("internal: loop metadata has 0 or 1 operand");
    o := md_op(md, 1);
    if o == NONE || ir.mds[o].kind != .VALUE return false, 0;
    v := ir.mds[o].value;
    if vkind(v) != .C_INT return false, 0;
    return true, ap_sext_value(const_ap(v));
}

// Loop::isSafeToClone
li_is_safe_to_clone :: (li: *Loop_Info, l: Loop_Id) -> bool {
    for bb: li_blocks(li, l) {
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .INDIRECTBR return false;
        for i: block_insts(bb) if is_call_base(i) && call_cannot_duplicate(i) return false;
    }
    return true;
}
// CallBase::cannotDuplicate is call_cannot_duplicate (pass_simplifycfg.jai)

// makePostTransformationMetadata(Context, OrigLoopID, RemovePrefixes, AddAttrs)
make_post_transformation_metadata :: (orig: Md_Id, remove_prefixes: [] string, add_attrs: [] Md_Id) -> Md_Id {
    mds: [..] Md_Id; mds.allocator = temp;
    array_add(*mds, NONE);
    if orig != NONE {
        n := md_nops(orig);
        if n > 1 for k: 1..n-1 {
            o := md_op(orig, k);
            is_vec := false;
            if md_is_node(o) && md_nops(o) > 0 {
                s := md_op(o, 0);
                if s != NONE && ir.mds[s].kind == .STRING for p: remove_prefixes if begins_with(ir.mds[s].str, p) { is_vec = true; break; }
            }
            if !is_vec array_add(*mds, o);
        }
    }
    for add_attrs array_add(*mds, it);
    return md_self_ref_loop_id(mds);
}
// MDNode::get/getDistinct(Context, MDs) with MDs[0] = nullptr, then replaceOperandWith(0, self): the node is distinct
// either way (a uniqued node that becomes self-referencing drops uniquing)
md_self_ref_loop_id :: (mds: [] Md_Id) -> Md_Id {
    m := md_tuple(mds, true);
    ir.md_ops[ir.mds[m].ops] = m;
    return m;
}
// Loop::addStringLoopAttribute(Name, RemovePrefixes)
li_add_string_loop_attribute :: (li: *Loop_Info, l: Loop_Id, name: string, remove_prefixes: [] string) {
    attr := md_tuple(.[md_string(name)], false);
    nid := make_post_transformation_metadata(li_loop_id(li, l), remove_prefixes, .[attr]);
    li_set_loop_id(li, l, nid);
}
// Loop::setLoopAlreadyUnrolled
li_set_loop_already_unrolled :: (li: *Loop_Info, l: Loop_Id) {
    li_add_string_loop_attribute(li, l, "llvm.loop.unroll.disable", .["llvm.loop.unroll."]);
}

// getLoopConvergenceHeart
li_loop_convergence_heart :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    for i: block_insts(li_header(li, l)) {
        if !is_call_base(i) continue;
        if !call_has_fn_attr(i, .Convergent) continue;
        tok := call_convergence_control_token(i);
        if tok != NONE {
            if !li_contains(li, l, inst_block(tok)) return i;
        }
        return NONE;
    }
    return NONE;
}
// CallBase::getConvergenceControlToken: the "convergencectrl" operand bundle's value
call_convergence_control_token :: (i: Value_Id) -> Value_Id {
    nb := call_num_bundles(i);
    if nb == 0 return NONE;
    for k: 0..cast(s64) nb - 1 {
        if call_bundle_tag(i, cast(u32) k) == "convergencectrl" return op(i, ir.u32_pool[inst(i).idx + 3 * cast(u32) k + 1]);
    }
    return NONE;
}

// ---------------------------------------------------------------- LoopUtils.cpp

TM_UNSPECIFIED :: 0; TM_ENABLE :: 1; TM_DISABLE :: 2; TM_FORCE :: 0x04; TM_FORCED_BY_USER :: TM_ENABLE | TM_FORCE;
TM_SUPPRESSED_BY_USER :: TM_DISABLE | TM_FORCE;

// createStringMetadata(TheLoop, Name, V)
create_string_metadata :: (name: string, v: u32) -> Md_Id {
    return md_tuple(.[md_string(name), md_value(const_int(type_int(32), cast(u64) v))], false);
}
// addStringMetadataToLoop(TheLoop, StringMD, V)
add_string_metadata_to_loop :: (li: *Loop_Info, l: Loop_Id, string_md: string, v: u32) {
    mds: [..] Md_Id; mds.allocator = temp;
    array_add(*mds, NONE);
    loop_id := li_loop_id(li, l);
    if loop_id != NONE {
        n := md_nops(loop_id);
        if n > 1 for k: 1..n-1 {
            node := md_op(loop_id, k);
            if md_nops(node) == 2 {
                s := md_op(node, 0);
                if s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == string_md {
                    o := md_op(node, 1);
                    if o != NONE && ir.mds[o].kind == .VALUE && vkind(ir.mds[o].value) == .C_INT &&
                       ap_sext_value(const_ap(ir.mds[o].value)) == cast(s64) v return;
                    continue;
                }
            }
            array_add(*mds, node);
        }
    }
    array_add(*mds, create_string_metadata(string_md, v));
    li_set_loop_id(li, l, md_self_ref_loop_id(mds));
}

// makeFollowupLoopID(OrigLoopID, FollowupOptions, InheritOptionsExceptPrefix = nullptr, AlwaysNew = false):
// (has value, the id (NONE = nullptr))
make_followup_loop_id :: (orig: Md_Id, followups: [] string, inherit_except_prefix: *string = null, always_new := false) -> (bool, Md_Id) {
    if orig == NONE {
        if always_new return true, NONE;
        return false, NONE;
    }
    inherit_all := inherit_except_prefix == null;
    inherit_some := inherit_except_prefix != null && inherit_except_prefix.count != 0;
    mds: [..] Md_Id; mds.allocator = temp;
    array_add(*mds, NONE);
    changed := false;
    n := md_nops(orig);
    if inherit_all || inherit_some {
        if n > 1 for k: 1..n-1 {
            o := md_op(orig, k);
            inherit := false;
            if inherit_some {
                if md_nops(o) == 0 inherit = true;
                else {
                    nm := md_op(o, 0);
                    if nm == NONE || ir.mds[nm].kind != .STRING inherit = true;
                    else inherit = !begins_with(ir.mds[nm].str, inherit_except_prefix.*);
                }
            }
            if inherit array_add(*mds, o);
            else changed = true;
        }
    } else {
        changed = n > 1;
    }
    has_any := false;
    for name: followups {
        fnode := find_option_md_for_loop_id(orig, name);
        if fnode == NONE continue;
        has_any = true;
        fn := md_nops(fnode);
        if fn > 1 for k: 1..fn-1 { array_add(*mds, md_op(fnode, k)); changed = true; }
    }
    if !always_new && !has_any return false, NONE;
    if !always_new && !changed return true, orig;
    if mds.count == 1 return true, NONE;
    return true, md_self_ref_loop_id(mds);
}

// hasDisableAllTransformsHint
li_has_disable_all_transforms_hint :: (li: *Loop_Info, l: Loop_Id) -> bool {
    return li_get_boolean_loop_attribute(li, l, "llvm.loop.disable_nonforced");
}
// hasUnrollTransformation
li_has_unroll_transformation :: (li: *Loop_Info, l: Loop_Id) -> s64 {
    if li_get_boolean_loop_attribute(li, l, "llvm.loop.unroll.disable") return TM_SUPPRESSED_BY_USER;
    has_count, count := li_optional_int_loop_attribute(li, l, "llvm.loop.unroll.count");
    if has_count return ifx cast,trunc(s32) count == 1 then TM_SUPPRESSED_BY_USER else TM_FORCED_BY_USER;
    if li_get_boolean_loop_attribute(li, l, "llvm.loop.unroll.enable") return TM_FORCED_BY_USER;
    if li_get_boolean_loop_attribute(li, l, "llvm.loop.unroll.full") return TM_FORCED_BY_USER;
    if li_has_disable_all_transforms_hint(li, l) return TM_DISABLE;
    return TM_UNSPECIFIED;
}
// hasUnrollAndJamTransformation
li_has_unroll_and_jam_transformation :: (li: *Loop_Info, l: Loop_Id) -> s64 {
    if li_get_boolean_loop_attribute(li, l, "llvm.loop.unroll_and_jam.disable") return TM_SUPPRESSED_BY_USER;
    has_count, count := li_optional_int_loop_attribute(li, l, "llvm.loop.unroll_and_jam.count");
    if has_count return ifx cast,trunc(s32) count == 1 then TM_SUPPRESSED_BY_USER else TM_FORCED_BY_USER;
    if li_get_boolean_loop_attribute(li, l, "llvm.loop.unroll_and_jam.enable") return TM_FORCED_BY_USER;
    if li_has_disable_all_transforms_hint(li, l) return TM_DISABLE;
    return TM_UNSPECIFIED;
}

// getExpectedExitLoopLatchBranch
li_expected_exit_loop_latch_branch :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    latch := li_loop_latch(li, l);
    if latch == NONE return NONE;
    t := block_terminator(latch);
    if t == NONE || inst_op(t) != .CONDBR || !li_is_loop_exiting(li, l, latch) return NONE;
    return t;
}
// extractBranchWeights(I, TrueVal, FalseVal)
extract_branch_weights_2u :: (i: Value_Id) -> (bool, u64, u64) {
    ok, w := prof_extract_branch_weights(i);
    if !ok || w.count != 2 return false, 0, 0;
    return true, w[0], w[1];
}
// estimateLoopTripCount
li_estimate_loop_trip_count :: (li: *Loop_Info, l: Loop_Id) -> (bool, u32) {
    br := li_expected_exit_loop_latch_branch(li, l);
    if br == NONE return false, 0;
    ok, loop_w, exit_w := extract_branch_weights_2u(br);
    if !ok return false, 0;
    if li_contains(li, l, get_successor(br, 1)) { t := loop_w; loop_w = exit_w; exit_w = t; }
    if exit_w == 0 return false, 0;
    // divideNearest
    exit_count := loop_w / exit_w + ifx (loop_w % exit_w) >= exit_w - exit_w / 2 then cast(u64) 1 else 0;
    if exit_count >= 0xFFFF_FFFF return true, 0xFFFF_FFFF;
    return true, cast(u32) (exit_count + 1);
}
// getLoopEstimatedTripCount(L, EstimatedLoopInvocationWeight = nullptr)
li_loop_estimated_trip_count :: (li: *Loop_Info, l: Loop_Id) -> (bool, u32) {
    br := li_expected_exit_loop_latch_branch(li, l);
    if br == NONE return false, 0;
    has, tc := li_optional_int_loop_attribute(li, l, "llvm.loop.estimated_trip_count");
    if has {
        t := cast,trunc(u32) tc;
        if t == 0 return false, 0;
        return true, t;
    }
    ok, r := li_estimate_loop_trip_count(li, l);
    return ok, r;
}
// setLoopEstimatedTripCount(L, EstimatedTripCount, EstimatedloopInvocationWeight = nullopt)
li_set_loop_estimated_trip_count :: (li: *Loop_Info, l: Loop_Id, tc: u32) -> bool {
    br := li_expected_exit_loop_latch_branch(li, l);
    if br == NONE return false;
    add_string_metadata_to_loop(li, l, "llvm.loop.estimated_trip_count", tc);
    return true;
}

// ---------------------------------------------------------------- BranchProbability

// BranchProbability: numerator over 1<<31; UNKNOWN = 0xFFFF_FFFF
Bprob :: u32;
BPROB_D :: cast(u32) (1 << 31);
BPROB_UNKNOWN :: cast(u32) 0xFFFF_FFFF;
bprob_one :: () -> Bprob { return BPROB_D; }
bprob_zero :: () -> Bprob { return 0; }
bprob_is_unknown :: (p: Bprob) -> bool { return p == BPROB_UNKNOWN; }
bprob_compl :: (p: Bprob) -> Bprob { return BPROB_D - p; }
// BranchProbability(Numerator, Denominator) / getBranchProbability(Numerator, Denominator)
bprob_get :: (n: u64, d: u64) -> Bprob {
    num := n; den := d;
    // getBranchProbability(uint64_t, uint64_t): scale down the denominator to fit 32 bits
    scale: u64 = 0;
    while (den >> scale) > 0xFFFF_FFFF scale += 1;
    num >>= scale; den >>= scale;
    // BranchProbability(uint32_t Numerator, uint32_t Denominator)
    if den == BPROB_D return cast(u32) num;
    prob := (num * cast(u64) BPROB_D + den / 2) / den;
    return cast(u32) prob;
}
// getBranchProbability(double Prob)
bprob_from_double :: (prob: float64) -> Bprob {
    // round(Prob * D), clamped by the assertion 0 <= Prob <= 1
    return cast(u32) cast(s64) lu_round(prob * cast(float64) BPROB_D);
}
bprob_to_double :: (p: Bprob) -> float64 { return cast(float64) p / cast(float64) BPROB_D; }
// operator*(BranchProbability)
bprob_mul :: (a: Bprob, b: Bprob) -> Bprob {
    prod := cast(u64) a * cast(u64) b;
    return cast(u32) ((prod + BPROB_D / 2) / BPROB_D);
}
// operator/(BranchProbability): getBranchProbability(Numerator, RHS.N)... (BranchProbability.h operator/=)
bprob_div :: (a: Bprob, b: Bprob) -> Bprob {
    return cast(u32) ((cast(u64) a * cast(u64) BPROB_D + b / 2) / b);
}
bprob_sub :: (a: Bprob, b: Bprob) -> Bprob { return ifx a < b then cast(u32) 0 else a - b; }
// pow(N)
bprob_pow :: (p: Bprob, n: u32) -> Bprob {
    r := bprob_one();
    for 1..n r = bprob_mul(r, p);
    return r;
}

// getBranchProbability(CondBrInst *B, bool ForFirstTarget)
cond_br_probability :: (b: Value_Id, for_first: bool) -> Bprob {
    ok, w0, w1 := extract_branch_weights_2u(b);
    if !ok return BPROB_UNKNOWN;
    den := w0 + w1;
    if den == 0 return BPROB_UNKNOWN;
    if !for_first { t := w0; w0 = w1; w1 = t; }
    return bprob_get(w0, den);
}
// getBranchProbability(BasicBlock *Src, BasicBlock *Dst)
edge_branch_probability :: (src: Value_Id, dst: Value_Id) -> Bprob {
    t := block_terminator(src);
    if t == NONE || num_successors(t) == 0 return bprob_zero();
    ok, w := prof_extract_branch_weights(t);
    if !ok return BPROB_UNKNOWN;
    total: u64 = 0;
    num: u32 = 0;
    for w {
        if get_successor(t, cast(u32) it_index) == dst num += cast(u32) it;
        total += it;
    }
    if total == 0 || total > 0xFFFF_FFFF return BPROB_UNKNOWN;
    return bprob_get(num, total);
}
// setBranchProbability(CondBrInst *B, BranchProbability P, bool ForFirstTarget)
set_cond_br_probability :: (b: Value_Id, p: Bprob, for_first: bool) {
    p0 := p; p1 := bprob_compl(p);
    if !for_first { t := p0; p0 = p1; p1 = t; }
    prof_set_branch_weights(b, .[p0, p1], false);
}
// getLoopProbability
li_loop_probability :: (li: *Loop_Info, l: Loop_Id) -> Bprob {
    br := li_expected_exit_loop_latch_branch(li, l);
    if br == NONE return BPROB_UNKNOWN;
    return cond_br_probability(br, get_successor(br, 0) == li_header(li, l));
}
// setLoopProbability
li_set_loop_probability :: (li: *Loop_Info, l: Loop_Id, p: Bprob) -> bool {
    br := li_expected_exit_loop_latch_branch(li, l);
    if br == NONE return false;
    set_cond_br_probability(br, p, get_successor(br, 0) == li_header(li, l));
    return true;
}
lu_round :: (x: float64) -> float64 #foreign cfc_libm "round";
