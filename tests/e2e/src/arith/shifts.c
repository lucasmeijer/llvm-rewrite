#include <stdio.h>
int main(void) {
  int s = -12345;
  unsigned u = 0xdeadbeefu;
  long long l = -9876543210LL;
  unsigned long long ul = 0xfedcba9876543210ULL;
  for (int k = 0; k < 32; k += 3)
    printf("%d %d %u %u\n", s >> k, (s & 0xffff) << (k % 15), u >> k, u << k);
  for (int k = 0; k < 64; k += 7)
    printf("%lld %llu %llu\n", l >> k, ul >> k, ul << k);
  return 0;
}
