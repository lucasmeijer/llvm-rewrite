#include <math.h>
#include <stdio.h>
float fadd(float, float); float fmul(float, float); double ddiv(double, double); double dsub(double, double);
double fma_like(double, double, double); int fcmp_all(double, double); double neg(double); float to_float(double);
double to_double(float); int d2i(double); long long d2ll(double); unsigned d2u(double); double i2d(int);
double u2d(unsigned); double ull2d(unsigned long long); float ll2f(long long);
static const double V[] = {0.0, -0.0, 1.0, -1.5, 3.25, 1e-310, 1e300, -2147483648.0, 4294967295.0, 0.1, NAN, INFINITY, -INFINITY};
#define NV (int)(sizeof V / sizeof V[0])
int main(void) {
  for (int i = 0; i < NV; i++) {
    double a = V[i];
    printf("%a %a %a %a\n", neg(a), (double)to_float(a), to_double((float)a), fma_like(a, 2.0, -1.0));
    if (!isnan(a) && a > -2147483649.0 && a < 2147483648.0) printf("  %d %lld\n", d2i(a), d2ll(a));
    if (!isnan(a) && a > -1.0 && a < 4294967296.0) printf("  %u\n", d2u(a));
    for (int j = 0; j < NV; j++) {
      double b = V[j];
      printf("  %a %a %a %a %d\n", (double)fadd((float)a, (float)b), (double)fmul((float)a, (float)b), ddiv(a, b), dsub(a, b), fcmp_all(a, b));
    }
  }
  int is[] = {0, 1, -1, 2147483647, -2147483647 - 1};
  for (int i = 0; i < 5; i++) printf("%a %a\n", i2d(is[i]), u2d((unsigned)is[i]));
  unsigned long long us[] = {0, 1, 9007199254740993ULL, 18446744073709551615ULL, 1ULL << 63};
  for (int i = 0; i < 5; i++) printf("%a %a\n", ull2d(us[i]), (double)ll2f((long long)us[i]));
  return 0;
}
