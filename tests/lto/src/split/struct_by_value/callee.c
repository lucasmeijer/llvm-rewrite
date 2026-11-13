#include "s.h"
int f1(struct s1 s) { return s.c * 2; }
int f8(struct s8 s) { return s.a - s.b; }
long f16(struct s16 s) { return s.a * s.b; }
long f24(struct s24 s) { return s.a + s.b + s.c; }
float ff(struct sf s) { return s.x * s.y; }
double fd(struct sd s) { return s.x * s.n; }
int f3(struct s3 s) { return s.c[0] + s.c[1] * 2 + s.c[2] * 3; }
struct s8 r8(int a) { struct s8 s = {a, a * 2}; return s; }
struct s16 r16(long a) { struct s16 s = {a, -a}; return s; }
struct s24 r24(long a) { struct s24 s = {a, a + 1, a + 2}; return s; }
struct sf rf(float a) { struct sf s = {a, a / 2}; return s; }
struct sd rd(double a) { struct sd s = {a, 7}; return s; }
