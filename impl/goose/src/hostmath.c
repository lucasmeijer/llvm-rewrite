// Host libm calls for constant folding (hostmath.goose). LLVM's ConstantFolding.cpp folds math functions by
// calling the host's double-precision libm (ConstantFoldFP / ConstantFoldBinaryFP) and rejects the fold when
// the call sets errno to EDOM/ERANGE or raises an FP exception other than inexact (llvm_fenv_clearexcept /
// llvm_fenv_testexcept in ConstantFolding.cpp). The same glibc libm that LLVM's opt links against is used
// here, so the results are bit-identical. Values cross as IEEE double bit patterns.
#include <errno.h>
#include <fenv.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

typedef double (*hm_fn1)(double);
typedef double (*hm_fn2)(double, double);

// keep in sync with the HM1_* / HM2_* ids in hostmath.goose
static hm_fn1 const hm_table1[] = { log, log2, log10, exp, sin, cos, sinh, cosh, atan, sqrt,
                                    acos, asin, tan, tanh, logb, log1p, erf, exp2, cbrt, expm1,
                                    asinh, acosh, atanh };
static hm_fn2 const hm_table2[] = { pow, atan2, fmod, nextafter, remainder, hypot };

static double hm_d(uint64_t b) { double d; memcpy(&d, &b, 8); return d; }
static uint64_t hm_b(double d) { uint64_t b; memcpy(&b, &d, 8); return b; }
static void hm_clear(void) { feclearexcept(FE_ALL_EXCEPT); errno = 0; }
static int32_t hm_ok(void) {
    int e = errno;
    int bad = (e == ERANGE || e == EDOM) || fetestexcept(FE_ALL_EXCEPT & ~FE_INEXACT);
    if (bad) feclearexcept(FE_ALL_EXCEPT);
    return bad ? 0 : 1;
}

uint64_t goose_hm_call1(int32_t id, uint64_t x, int32_t *ok) {
    hm_fn1 volatile f = hm_table1[id];   // volatile: a real call, ordered between the fenv accesses
    hm_clear();
    double r = f(hm_d(x));
    *ok = hm_ok();
    return hm_b(r);
}
uint64_t goose_hm_call2(int32_t id, uint64_t x, uint64_t y, int32_t *ok) {
    hm_fn2 volatile f = hm_table2[id];
    hm_clear();
    double r = f(hm_d(x), hm_d(y));
    *ok = hm_ok();
    return hm_b(r);
}
// std::pow(float, int) in C++ is pow((double)x, (double)n); no fenv check (powi folding has none)
uint64_t goose_hm_pow_noexc(uint64_t x, uint64_t y) {
    hm_fn2 volatile f = pow;
    return hm_b(f(hm_d(x), hm_d(y)));
}
// ilogb(APFloat) is LLVM's own; the double ilogb is not needed
// std::log2(float) (C++ overload: logf-precision log2f), for replacePowWithExp's exp2(log2(n) * x)
uint32_t goose_hm_log2f(uint32_t x) {
    float (*volatile f)(float) = log2f;
    float d; memcpy(&d, &x, 4);
    float r = f(d);
    uint32_t b; memcpy(&b, &r, 4);
    return b;
}
