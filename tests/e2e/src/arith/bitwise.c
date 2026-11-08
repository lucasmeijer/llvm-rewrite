#include <stdio.h>
int main(void) {
  unsigned a = 0xf0f0a5a5u, b = 0x0ff01234u;
  printf("%08x %08x %08x %08x\n", a & b, a | b, a ^ b, ~a);
  unsigned long long x = 0x123456789abcdef0ULL;
  printf("%016llx %016llx\n", x & ~0xffULL, x ^ (x >> 17));
  int n = -1;
  printf("%d %d\n", n & 0x7f, n ^ 0x55);
  return 0;
}
