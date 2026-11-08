#include <stdio.h>
int main(void) {
  unsigned vals[] = {1u, 0x80000000u, 0xf0f0f0f0u, 12345u, 0xffffffffu};
  for (int i = 0; i < 5; i++) {
    unsigned v = vals[i];
    printf("%d %d %d %08x %d\n", __builtin_popcount(v), __builtin_clz(v), __builtin_ctz(v), __builtin_bswap32(v), __builtin_parity(v));
  }
  unsigned long long w = 0x0123456789abcdefULL;
  printf("%d %d %016llx\n", __builtin_popcountll(w), __builtin_clzll(w), __builtin_bswap64(w));
  int r;
  int of = __builtin_add_overflow(2147483600, 100, &r);
  long m;
  int of2 = __builtin_mul_overflow(3037000500L, 3037000500L, &m);
  printf("%d %d %d %ld\n", of, r, of2, m);
  int a = -17;
  printf("%d %d %d\n", __builtin_abs(a), __builtin_expect(a, 0) < 0, a < 0 ? -a : a);
  return 0;
}
