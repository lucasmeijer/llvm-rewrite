#include <stdio.h>
#include <stddef.h>
void reverse(int *, size_t); long dot(const short *, const short *, int); void prefix_sum(double *, int);
size_t count_byte(const unsigned char *, size_t, unsigned char); void transpose4(float m[4][4]);
struct pair { int key; long val; }; long find(const struct pair *, int, int);
int main(void) {
  int a[17]; for (int i = 0; i < 17; i++) a[i] = i * i; reverse(a, 17); reverse(a, 0);
  for (int i = 0; i < 17; i++) printf("%d ", a[i]); printf("\n");
  short x[33], y[33]; for (int i = 0; i < 33; i++) { x[i] = (short)(i * 1000 - 16000); y[i] = (short)(i - 16); }
  printf("%ld\n", dot(x, y, 33));
  double d[10]; for (int i = 0; i < 10; i++) d[i] = i * 0.5; prefix_sum(d, 10); printf("%.2f %.2f\n", d[4], d[9]);
  unsigned char buf[300]; for (int i = 0; i < 300; i++) buf[i] = (unsigned char)(i * 7); printf("%zu\n", count_byte(buf, 300, 14));
  float m[4][4]; for (int i = 0; i < 16; i++) m[i / 4][i % 4] = i; transpose4(m); printf("%.0f %.0f %.0f\n", m[0][1], m[1][0], m[3][2]);
  struct pair ps[5] = {{1, 10}, {5, 50}, {-3, -30}, {7, 70000000000L}, {9, 90}};
  printf("%ld %ld %ld\n", find(ps, 5, 7), find(ps, 5, -3), find(ps, 5, 4));
  return 0;
}
