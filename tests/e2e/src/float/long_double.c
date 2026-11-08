#include <stdio.h>
int main(void) {
  long double a = 1.0L / 3.0L;
  long double b = a * 3.0L - 1.0L;
  long double c = 0;
  for (int i = 1; i <= 50; i++) c += 1.0L / ((long double)i * i);
  printf("%.18Lf %d %.18Lf\n", a, b < 1e-10L && b > -1e-10L, c);
  double d = (double)c;
  long long n = (long long)(c * 1e15L);
  printf("%.17g %lld %d\n", d, n, a < 0.34L);
  return 0;
}
