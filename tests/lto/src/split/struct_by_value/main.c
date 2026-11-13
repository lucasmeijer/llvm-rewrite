#include <stdio.h>
#include "s.h"
int main(void) {
  struct s1 a = {21}; struct s8 b = {10, 3}; struct s16 c = {6, 7}; struct s24 d = {1, 2, 3};
  struct sf e = {1.5f, 4.0f}; struct sd g = {2.5, 4}; struct s3 h = {{1, 2, 3}};
  printf("%d %d %ld %ld %.2f %.2f %d\n", f1(a), f8(b), f16(c), f24(d), ff(e), fd(g), f3(h));
  struct s8 x = r8(5); struct s16 y = r16(9); struct s24 z = r24(100); struct sf w = rf(3); struct sd v = rd(0.5);
  printf("%d %d %ld %ld %ld %ld %ld %.2f %.2f %.2f %ld\n", x.a, x.b, y.a, y.b, z.a, z.b, z.c, w.x, w.y, v.x, v.n);
  return 0;
}
