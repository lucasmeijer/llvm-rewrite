#include <stdio.h>
int main(void) {
  unsigned x = 0;
  x -= 1;
  unsigned long long y = 0xffffffffffffffffULL;
  y += 2;
  unsigned char c = 250;
  c += 10;
  printf("%u %llu %u\n", x, y, c);
  unsigned h = 2166136261u;
  for (int i = 0; i < 100; i++) h = (h ^ (unsigned)i) * 16777619u;
  printf("%u\n", h);
  return 0;
}
