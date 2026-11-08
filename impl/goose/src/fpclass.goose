// KnownFPClass / computeKnownFPClass (llvm/lib/Analysis/ValueTracking.cpp, llvm/lib/Support/KnownFPClass.cpp),
// fcmpToClassTest (llvm/lib/Analysis/FloatingPointPredicateUtils.cpp), ConstantFPRange
// (llvm/lib/IR/ConstantFPRange.cpp) and the FP isImpliedCondition path.
// Coverage: constants are handled; every other value fails loudly (not ported yet).
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import apfloat;
import pm;
import knownbits;
import constfold;

let FCL_SNAN: u64 = 1;
let FCL_QNAN: u64 = 2;
let FCL_NEG_INF: u64 = 4;
let FCL_NEG_NORMAL: u64 = 8;
let FCL_NEG_SUBNORMAL: u64 = 16;
let FCL_NEG_ZERO: u64 = 32;
let FCL_POS_ZERO: u64 = 64;
let FCL_POS_SUBNORMAL: u64 = 128;
let FCL_POS_NORMAL: u64 = 256;
let FCL_POS_INF: u64 = 512;
let FCL_NAN: u64 = 3;
let FCL_INF: u64 = 516;
let FCL_ALL: u64 = 1023;
let FCL_ORDERED_LT_ZERO_MASK: u64 = 28;   // fcNegSubnormal | fcNegNormal | fcNegInf

// sign: -1 unknown, 0 known positive (sign bit clear), 1 known negative
struct KFC { known: u64, sign: i64 }

fn kfc_unknown() -> KFC { KFC { known: FCL_ALL, sign: -1 } }
fn kfc_never_nan(k: KFC) -> bool { (k.known & FCL_NAN) == 0 }
fn kfc_always_nan(k: KFC) -> bool { (k.known & ~FCL_NAN & FCL_ALL) == 0 }
fn kfc_never(k: KFC, m: u64) -> bool { (k.known & m) == 0 }
// cannotBeOrderedLessThanZero: isKnownNever(OrderedLessThanZeroMask)
fn kfc_cannot_be_ordered_lt_zero(k: KFC) -> bool { (k.known & FCL_ORDERED_LT_ZERO_MASK) == 0 }

fn fp_not_ported(what: const u8[:]) { fatal(str("computeKnownFPClass: ", what, " is not ported yet")); }

// The FPClassTest of one ConstantFP (APFloat::classify)
fn cfp_class(c: i32) -> u64 {
    let p = cfp_parts(c);
    if p.cat == FC_NAN { return if cfp_is_signaling(c) { FCL_SNAN } else { FCL_QNAN }; }
    if p.cat == FC_INF { return if p.neg { FCL_NEG_INF } else { FCL_POS_INF }; }
    if p.cat == FC_ZERO { return if p.neg { FCL_NEG_ZERO } else { FCL_POS_ZERO }; }
    if p.expf == 0 { return if p.neg { FCL_NEG_SUBNORMAL } else { FCL_POS_SUBNORMAL }; }
    return if p.neg { FCL_NEG_NORMAL } else { FCL_POS_NORMAL };
}
fn cfp_is_signaling(c: i32) -> bool {
    let p = cfp_parts(c);
    if p.cat != FC_NAN { return false; }
    let f = fp_fmt(cfp_kind(c));
    // quiet bit: the top fraction bit
    let qb = f.p - 2;
    if cfp_kind(c) == TK_X86_FP80 { return ((cint_lo(c) >> 62) & 1) == 0; }
    if qb < 64 { return ((p.sig0 >> qb) & 1) == 0; }
    return ((p.sig1 >> (qb - 64)) & 1) == 0;
}

// computeKnownFPClass(V, FMF, InterestedClasses, Q) with the context in kb_cxt
recursive fn known_fp_class(v: i32, interested: u64, fmf: u8, depth: i64) -> KFC {
    var k = kfc_unknown();
    if is_constant(v) {
        if vals[v].kind == VK_CFP && !ty_is_vector(vals[v].ty) {
            let c = cfp_class(v);
            k.known = c;
            k.sign = if cfp_parts(v).neg { 1 } else { 0 };
            return k;
        }
        let ty = vals[v].ty;
        if ty_is_vector(ty) {
            let s = splat_value(v, false);
            if s >= 0 && vals[s].kind == VK_CFP {
                k.known = cfp_class(s);
                k.sign = if cfp_parts(s).neg { 1 } else { 0 };
                return k;
            }
            if ty_kind(ty) == TK_FVEC && (vals[v].kind == VK_CDVECTOR || vals[v].kind == VK_CVECTOR || vals[v].kind == VK_AGGZERO) {
                var known: u64 = 0;
                var sign: i64 = -2;
                for i in ty_count(ty) {
                    let e = agg_elem(v, i);
                    if e < 0 { return kfc_unknown(); }
                    if vals[e].kind == VK_POISON { continue; }
                    if vals[e].kind != VK_CFP { return kfc_unknown(); }
                    known |= cfp_class(e);
                    let s2 = if cfp_parts(e).neg { 1 } else { 0 };
                    if sign == -2 { sign = s2; } else if sign != s2 { sign = -1; }
                }
                k.known = known;
                k.sign = if sign == -2 { -1 } else { sign };
                return k;
            }
        }
        if vals[v].kind == VK_POISON { return KFC { known: 0, sign: -1 }; }
        if vals[v].kind == VK_UNDEF { return k; }
        if vals[v].kind == VK_AGGZERO { return KFC { known: FCL_POS_ZERO, sign: 0 }; }
        fp_not_ported("known FP class of this constant");
        return k;
    }
    fp_not_ported("known FP class of a non-constant value");
    return k;
}

// fcmpToClassTest(Pred, F, LHS, ConstRHS): returns (class value or -1, test mask)
fn fcmp_to_class_test(p: i64, fv: i32, l: i32, c: i32) -> i32, u64 {
    fp_not_ported("fcmpToClassTest");
    return -1, 0;
}

// ConstantFPRange (not ported): a CFR placeholder
struct CFR { lo: u64, hi: u64 }
fn fpr_exact_fcmp_region(p: i64, c: i32) -> bool, CFR {
    fp_not_ported("ConstantFPRange::makeExactFCmpRegion");
    return false, CFR { lo: 0, hi: 0 };
}
fn fpr_intersect(a: CFR, b: CFR) -> CFR { a }
fn fpr_is_empty(a: CFR) -> bool { false }
fn fpr_contains(a: CFR, b: CFR) -> bool { false }

// isImpliedCondition(LHS, fcmp Pred, L, R, LHSIsTrue)
fn implied_condition_fcmp(cond: i32, p: i64, l: i32, r: i32, lhs_true: bool) -> i64 {
    if is_op(cond, OP_FCMP) || is_op(cond, OP_AND) || is_op(cond, OP_OR) || is_inst_op(cond, OP_SELECT) || m_not(cond) >= 0 {
        fp_not_ported("isImpliedCondition for fcmp");
    }
    return -1;
}
