// Host libm for constant folding: the C side is hostmath.c (built through opt.build). See hostmath.c for why
// this reproduces LLVM bit for bit (LLVM folds with the host's libm too, and both use the same glibc).
import std;

let HM1_LOG = 0;
let HM1_LOG2 = 1;
let HM1_LOG10 = 2;
let HM1_EXP = 3;
let HM1_SIN = 4;
let HM1_COS = 5;
let HM1_SINH = 6;
let HM1_COSH = 7;
let HM1_ATAN = 8;
let HM1_SQRT = 9;
let HM1_ACOS = 10;
let HM1_ASIN = 11;
let HM1_TAN = 12;
let HM1_TANH = 13;
let HM1_LOGB = 14;
let HM1_LOG1P = 15;
let HM1_ERF = 16;

let HM2_POW = 0;
let HM2_ATAN2 = 1;
let HM2_FMOD = 2;
let HM2_NEXTAFTER = 3;

extern fn goose_hm_call1(id: i32, x: u64, ok: i32&) -> u64;
extern fn goose_hm_call2(id: i32, x: u64, y: u64, ok: i32&) -> u64;
extern fn goose_hm_pow_noexc(x: u64, y: u64) -> u64;

// f(x) on host doubles (bit patterns); ok = false when LLVM's fenv/errno test rejects the fold
fn hm_call1(id: i64, x: u64) -> u64, bool {
    var ok: i32 = 0;
    let r = goose_hm_call1(id as i32, x, ok);
    return r, ok != 0;
}
fn hm_call2(id: i64, x: u64, y: u64) -> u64, bool {
    var ok: i32 = 0;
    let r = goose_hm_call2(id as i32, x, y, ok);
    return r, ok != 0;
}
fn hm_pow_noexc(x: u64, y: u64) -> u64 { goose_hm_pow_noexc(x, y) }
