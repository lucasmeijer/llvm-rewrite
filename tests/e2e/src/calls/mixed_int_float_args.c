#include <stdio.h>
static double f(int a, double b, long c, float d, char e, double g, int h, float i, double j, double k, double l, double m, double n) {
  return a + b + c + d + e + g + h + i + j + k + l + m + n;
}
int main(void) {
  printf("%.4f\n", f(1, 2.5, 3, 4.25f, 5, 6.125, 7, 8.5f, 9, 10, 11, 12, 13.0625));
  return 0;
}
