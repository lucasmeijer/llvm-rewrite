#include <stdio.h>
long f(int a, long b, short c, char d, int e, long f, int g, long h, int i, char j, long k) {
  return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10 + k * 11;
}
int main(void) {
  printf("%ld\n", f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11));
  printf("%ld\n", f(-1, -2000000000000L, -3, -4, -5, 6, -7, 8, -9, 'x', 123456789012L));
  return 0;
}
