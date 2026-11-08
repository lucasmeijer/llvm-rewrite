#include <stdio.h>
struct s1 { char c; };
struct s8 { int a, b; };
struct s16 { long a, b; };
struct s24 { long a, b, c; };
struct sf { float x, y; };
struct sd { double x; long n; };
struct s3 { char c[3]; };
static int f1(struct s1 s) { return s.c * 2; }
static int f8(struct s8 s) { return s.a - s.b; }
static long f16(struct s16 s) { return s.a * s.b; }
static long f24(struct s24 s) { return s.a + s.b + s.c; }
static float ff(struct sf s) { return s.x * s.y; }
static double fd(struct sd s) { return s.x * s.n; }
static int f3(struct s3 s) { return s.c[0] + s.c[1] * 2 + s.c[2] * 3; }
static struct s8 r8(int a) { struct s8 s = {a, a * 2}; return s; }
static struct s16 r16(long a) { struct s16 s = {a, -a}; return s; }
static struct s24 r24(long a) { struct s24 s = {a, a + 1, a + 2}; return s; }
static struct sf rf(float a) { struct sf s = {a, a / 2}; return s; }
static struct sd rd(double a) { struct sd s = {a, 7}; return s; }
int main(void) {
  struct s1 a = {21}; struct s8 b = {10, 3}; struct s16 c = {6, 7}; struct s24 d = {1, 2, 3};
  struct sf e = {1.5f, 4.0f}; struct sd g = {2.5, 4}; struct s3 h = {{1, 2, 3}};
  printf("%d %d %ld %ld %.2f %.2f %d\n", f1(a), f8(b), f16(c), f24(d), ff(e), fd(g), f3(h));
  struct s8 x = r8(5); struct s16 y = r16(9); struct s24 z = r24(100); struct sf w = rf(3); struct sd v = rd(0.5);
  printf("%d %d %ld %ld %ld %ld %ld %.2f %.2f %.2f %ld\n", x.a, x.b, y.a, y.b, z.a, z.b, z.c, w.x, w.y, v.x, v.n);
  return 0;
}
