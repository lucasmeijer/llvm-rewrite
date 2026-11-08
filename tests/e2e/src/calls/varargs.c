#include <stdarg.h>
#include <stdio.h>
static long sum(int n, ...) {
  va_list ap;
  va_start(ap, n);
  long s = 0;
  for (int i = 0; i < n; i++) s += va_arg(ap, int);
  va_end(ap);
  return s;
}
static double mixed(int n, ...) {
  va_list ap;
  va_start(ap, n);
  double s = 0;
  for (int i = 0; i < n; i++) {
    if (i % 2) s += va_arg(ap, double);
    else s += va_arg(ap, long);
  }
  va_end(ap);
  return s;
}
int main(void) {
  printf("%ld\n", sum(10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10));
  printf("%.3f\n", mixed(8, 1L, 0.5, 2L, 0.25, 3L, 0.125, 4L, 1e10));
  return 0;
}
