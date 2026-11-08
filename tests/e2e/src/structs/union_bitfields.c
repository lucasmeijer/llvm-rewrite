#include <stdio.h>
#include <string.h>
union u { unsigned int i; float f; unsigned char b[4]; };
struct flags { unsigned a : 3; unsigned b : 5; signed c : 4; unsigned d : 20; };
int main(void) {
  union u x;
  x.f = 1.0f;
  printf("%08x %d %d\n", x.i, x.b[0], x.b[3]);
  struct flags f;
  memset(&f, 0, sizeof f);
  f.a = 5; f.b = 31; f.c = -3; f.d = 1000000;
  f.a += 4;
  printf("%u %u %d %u %zu\n", f.a, f.b, f.c, f.d, sizeof f);
  return 0;
}
