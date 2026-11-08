#include <stdio.h>
static unsigned rotl(unsigned x, int k) { return (x << k) | (x >> ((32 - k) & 31)); }
static int imin(int a, int b) { return a < b ? a : b; }
static unsigned umax(unsigned a, unsigned b) { return a > b ? a : b; }
int main(void) {
  unsigned x = 0x12345678u;
  for (int k = 1; k < 32; k += 5) printf("%08x ", rotl(x, k));
  printf("\n");
  int m = 1000; unsigned M = 0;
  for (int i = -50; i < 50; i += 7) { m = imin(m, i * i - 40); M = umax(M, (unsigned)(i * 31)); }
  printf("%d %u\n", m, M);
  return 0;
}
