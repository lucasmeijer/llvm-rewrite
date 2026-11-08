#include <stdio.h>
int main(void) {
  __int128 a = (__int128)1234567890123456789LL * 1000;
  unsigned __int128 b = (unsigned __int128)0xffffffffffffffffULL * 0xffffffffULL;
  __int128 q = a / 77, r = a % 77;
  printf("%llu %llu\n", (unsigned long long)(a >> 64), (unsigned long long)a);
  printf("%llu %llu\n", (unsigned long long)(b >> 64), (unsigned long long)b);
  printf("%lld %lld\n", (long long)q, (long long)r);
  printf("%d\n", a > (__int128)b);
  return 0;
}
