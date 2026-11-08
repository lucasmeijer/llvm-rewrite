// CmpInst / ICmpInst / FCmpInst / CmpPredicate predicate algebra: a port of the static helpers in
// llvm/lib/IR/Instructions.cpp (getInversePredicate, getSwappedPredicate, getSignedPredicate,
// getUnsignedPredicate, getFlippedSignednessPredicate, getStrictPredicate, getNonStrictPredicate,
// isImpliedByMatchingCmp, CmpPredicate::getMatching, ...). Predicates are u8 in CmpInst::Predicate numbering
// (FCMP 0..15, ICMP 32..41, constants in constfold.jai); CmpPredicate's samesign bit is passed separately.

is_fp_predicate :: (p: u8) -> bool { return p <= 15; }
icmp_is_signed :: (p: u8) -> bool { return p >= ICMP_SGT && p <= ICMP_SLE; }
icmp_is_unsigned :: (p: u8) -> bool { return p >= ICMP_UGT && p <= ICMP_ULE; }
icmp_is_equality :: (p: u8) -> bool { return p == ICMP_EQ || p == ICMP_NE; }
icmp_is_relational :: (p: u8) -> bool { return is_int_predicate(p) && !icmp_is_equality(p); }
fcmp_is_equality :: (p: u8) -> bool { return p == FCMP_OEQ || p == FCMP_ONE || p == FCMP_UEQ || p == FCMP_UNE; }
// CmpInst::isEquality
cmp_is_equality :: (p: u8) -> bool { if is_int_predicate(p) return icmp_is_equality(p); return fcmp_is_equality(p); }
cmp_is_ordered :: (p: u8) -> bool {
    return p == FCMP_OEQ || p == FCMP_ONE || p == FCMP_OGT || p == FCMP_OLT || p == FCMP_OGE || p == FCMP_OLE || p == FCMP_ORD;
}
cmp_is_unordered :: (p: u8) -> bool {
    return p == FCMP_UEQ || p == FCMP_UNE || p == FCMP_UGT || p == FCMP_ULT || p == FCMP_UGE || p == FCMP_ULE || p == FCMP_UNO;
}
// CmpInst::isTrueWhenEqual / isFalseWhenEqual
cmp_is_true_when_equal :: (p: u8) -> bool {
    return p == ICMP_EQ || p == ICMP_UGE || p == ICMP_ULE || p == ICMP_SGE || p == ICMP_SLE ||
           p == FCMP_TRUE || p == FCMP_UEQ || p == FCMP_UGE || p == FCMP_ULE;
}
cmp_is_false_when_equal :: (p: u8) -> bool {
    return p == ICMP_NE || p == ICMP_UGT || p == ICMP_ULT || p == ICMP_SGT || p == ICMP_SLT ||
           p == FCMP_FALSE || p == FCMP_ONE || p == FCMP_OGT || p == FCMP_OLT;
}
// CmpInst::isSigned / isUnsigned (FP predicates are neither)
cmp_is_signed :: (p: u8) -> bool { return icmp_is_signed(p); }
cmp_is_unsigned :: (p: u8) -> bool { return icmp_is_unsigned(p); }

icmp_inverse :: (p: u8) -> u8 {
    if p == {
        case ICMP_EQ; return ICMP_NE; case ICMP_NE; return ICMP_EQ;
        case ICMP_UGT; return ICMP_ULE; case ICMP_ULT; return ICMP_UGE; case ICMP_UGE; return ICMP_ULT; case ICMP_ULE; return ICMP_UGT;
        case ICMP_SGT; return ICMP_SLE; case ICMP_SLT; return ICMP_SGE; case ICMP_SGE; return ICMP_SLT; case ICMP_SLE; return ICMP_SGT;
    }
    if p <= 15 return 15 - p;   // FCMP_OEQ <-> FCMP_UNE etc.
    return p;
}
cmp_inverse :: (p: u8) -> u8 { return icmp_inverse(p); }
icmp_swapped :: (p: u8) -> u8 { return swapped_predicate(p); }
cmp_swapped :: (p: u8) -> u8 { return swapped_predicate(p); }
icmp_signed_predicate :: (p: u8) -> u8 {
    if p == { case ICMP_UGT; return ICMP_SGT; case ICMP_ULT; return ICMP_SLT; case ICMP_UGE; return ICMP_SGE; case ICMP_ULE; return ICMP_SLE; }
    return p;
}
icmp_unsigned_predicate :: (p: u8) -> u8 {
    if p == { case ICMP_SGT; return ICMP_UGT; case ICMP_SLT; return ICMP_ULT; case ICMP_SGE; return ICMP_UGE; case ICMP_SLE; return ICMP_ULE; }
    return p;
}
icmp_flipped_signedness :: (p: u8) -> u8 {
    if icmp_is_equality(p) return p;
    if icmp_is_signed(p) return icmp_unsigned_predicate(p);
    return icmp_signed_predicate(p);
}
// CmpPredicate::getPreferredSignedPredicate
icmp_preferred_signed_predicate :: (p: u8, samesign := true) -> u8 { if samesign return icmp_signed_predicate(p); return p; }
cmp_is_strict :: (p: u8) -> bool {
    return p == ICMP_SGT || p == ICMP_SLT || p == ICMP_UGT || p == ICMP_ULT || p == FCMP_OGT || p == FCMP_OLT || p == FCMP_UGT || p == FCMP_ULT;
}
cmp_is_non_strict :: (p: u8) -> bool {
    return p == ICMP_SGE || p == ICMP_SLE || p == ICMP_UGE || p == ICMP_ULE || p == FCMP_OGE || p == FCMP_OLE || p == FCMP_UGE || p == FCMP_ULE;
}
cmp_strict :: (p: u8) -> u8 {
    if p == {
        case ICMP_SGE; return ICMP_SGT; case ICMP_SLE; return ICMP_SLT; case ICMP_UGE; return ICMP_UGT; case ICMP_ULE; return ICMP_ULT;
        case FCMP_OGE; return FCMP_OGT; case FCMP_OLE; return FCMP_OLT; case FCMP_UGE; return FCMP_UGT; case FCMP_ULE; return FCMP_ULT;
    }
    return p;
}
cmp_non_strict :: (p: u8) -> u8 {
    if p == {
        case ICMP_SGT; return ICMP_SGE; case ICMP_SLT; return ICMP_SLE; case ICMP_UGT; return ICMP_UGE; case ICMP_ULT; return ICMP_ULE;
        case FCMP_OGT; return FCMP_OGE; case FCMP_OLT; return FCMP_OLE; case FCMP_UGT; return FCMP_UGE; case FCMP_ULT; return FCMP_ULE;
    }
    return p;
}
// CmpInst::getFlippedStrictnessPredicate
cmp_flipped_strictness :: (p: u8) -> u8 { if cmp_is_strict(p) return cmp_non_strict(p); if cmp_is_non_strict(p) return cmp_strict(p); return p; }
// FCmpInst::getOrderedPredicate / getUnorderedPredicate
fcmp_ordered :: (p: u8) -> u8 { return p & 0x7; }   // FCMP_U* = FCMP_O* | 8
fcmp_unordered :: (p: u8) -> u8 { return p | 0x8; }

// CmpPredicate::getMatching: (ok, pred, samesign)
cmp_get_matching :: (a: u8, a_ss: bool, b: u8, b_ss: bool) -> (bool, u8, bool) {
    if a == b return true, a, a_ss && b_ss;
    if is_fp_predicate(a) || is_fp_predicate(b) return false, 0, false;
    if a_ss && a == icmp_flipped_signedness(b) return true, b, false;
    if b_ss && b == icmp_flipped_signedness(a) return true, a, false;
    return false, 0, false;
}
icmp_implied_true_by_matching :: (p1_in: u8, ss1: bool, p2_in: u8, ss2: bool) -> bool {
    p1 := p1_in; p2 := p2_in;
    ok := cmp_get_matching(p1, ss1, p2, ss2);
    if ok return true;
    if ss1 && cmp_is_signed(p2) p1 = icmp_flipped_signedness(p1);
    else if ss2 && cmp_is_signed(p1) p2 = icmp_flipped_signedness(p2);
    if p1 == {
        case ICMP_EQ; return p2 == ICMP_UGE || p2 == ICMP_ULE || p2 == ICMP_SGE || p2 == ICMP_SLE;
        case ICMP_UGT; return p2 == ICMP_NE || p2 == ICMP_UGE;
        case ICMP_ULT; return p2 == ICMP_NE || p2 == ICMP_ULE;
        case ICMP_SGT; return p2 == ICMP_NE || p2 == ICMP_SGE;
        case ICMP_SLT; return p2 == ICMP_NE || p2 == ICMP_SLE;
    }
    return false;
}
// ICmpInst::isImpliedByMatchingCmp: 1 true, 0 false, -1 unknown
icmp_implied_by_matching_cmp :: (p1: u8, ss1: bool, p2: u8, ss2: bool) -> s8 {
    if icmp_implied_true_by_matching(p1, ss1, p2, ss2) return 1;
    if icmp_implied_true_by_matching(p1, ss1, icmp_inverse(p2), ss2) return 0;
    return -1;
}
// ICmpInst::compare(KnownBits, KnownBits, Pred)
icmp_compare_known :: (l: Known_Bits, r: Known_Bits, p: u8) -> s8 {
    if p == {
        case ICMP_EQ; return kb_cmp_eq(l, r);
        case ICMP_NE; return kb_cmp_ne(l, r);
        case ICMP_UGE; return kb_cmp_uge(l, r);
        case ICMP_UGT; return kb_cmp_ugt(l, r);
        case ICMP_ULE; return kb_cmp_ule(l, r);
        case ICMP_ULT; return kb_cmp_ult(l, r);
        case ICMP_SGE; return kb_cmp_sge(l, r);
        case ICMP_SGT; return kb_cmp_sgt(l, r);
        case ICMP_SLE; return kb_cmp_sle(l, r);
        case ICMP_SLT; return kb_cmp_slt(l, r);
    }
    fatal("internal: icmp_compare_known with a non-integer predicate");
    return -1;
}
