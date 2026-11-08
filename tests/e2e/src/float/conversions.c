#include <stdio.h>
int main(void) {
  double ds[] = {0.0, -0.5, 1.5, -2.75, 123456.789, 4294967295.0, -2147483648.0};
  for (int i = 0; i < 7; i++) {
    double d = ds[i];
    printf("%lld %lld %.3f %.3f\n", (long long)d, (long long)d, (float)d, (double)(float)d);
    if (d >= 0) printf("%u %llu\n", (unsigned)d, (unsigned long long)d);
  }
  unsigned long long big = 18446744073709551615ULL;
  long long neg = -9007199254740993LL;
  unsigned u = 4294967295u;
  printf("%.1f %.1f %.1f %.1f\n", (double)big, (double)neg, (double)u, (float)big);
  char c = -7; unsigned char uc = 250; short s = -1234;
  printf("%.1f %.1f %.1f\n", (double)c, (float)uc, (double)s);
  return 0;
}
