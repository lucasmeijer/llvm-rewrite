#include <math.h>
#include <stdio.h>
int main(void) {
  for (double x = 0.1; x < 3.0; x += 0.7)
    printf("%.12f %.12f %.12f %.12f %.12f\n", sqrt(x), sin(x), exp(x), log(x), pow(x, 1.5));
  printf("%.3f %.3f %.3f %.3f\n", floor(-2.5), ceil(-2.5), fabs(-3.25), fmod(10.5, 3.0));
  printf("%.6f %.6f\n", sqrtf(2.0f), fmaxf(1.0f, -2.0f));
  return 0;
}
