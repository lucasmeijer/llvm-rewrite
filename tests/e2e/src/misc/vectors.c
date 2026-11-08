#include <stdio.h>
typedef int v4i __attribute__((vector_size(16)));
typedef float v4f __attribute__((vector_size(16)));
typedef double v2d __attribute__((vector_size(16)));
int main(void) {
  v4i a = {1, 2, 3, 4}, b = {10, 20, 30, 40};
  v4i c = a * b + (b >> 1) - (a & 1);
  v4f f = {1.5f, -2.0f, 0.25f, 8.0f};
  v4f g = f * f + 1.0f;
  v2d d = {3.0, 4.0};
  d = d / 2.0;
  printf("%d %d %d %d\n", c[0], c[1], c[2], c[3]);
  printf("%.3f %.3f %.3f %.3f\n", g[0], g[1], g[2], g[3]);
  printf("%.3f %.3f\n", d[0], d[1]);
  v4i m = a > (v4i){2, 2, 2, 2};
  printf("%d %d %d %d\n", m[0], m[1], m[2], m[3]);
  return 0;
}
