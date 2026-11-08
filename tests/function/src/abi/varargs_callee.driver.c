#include <stdio.h>
double vsum(const char *fmt, ...);
double vforward(int n, ...);
int main(void) {
  int k = 1000;
  printf("%.3f\n", vsum("i", 5));
  printf("%.3f\n", vsum("ididid", 1, 0.5, 2, 0.25, 3, 0.125));
  printf("%.3f\n", vsum("llllllllld", 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 1e-3));
  printf("%.3f\n", vsum("ddddddddddi", 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11));
  printf("%.3f\n", vsum("pip", &k, 7, &k));
  printf("%.3f\n", vforward(10, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0));
  return 0;
}
