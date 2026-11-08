#include <complex.h>
#include <stdio.h>
int main(void) {
  double complex z = 1.0 + 2.0 * I;
  double complex w = 3.0 - 1.0 * I;
  double complex p = z * w, q = z / w;
  printf("%.6f %.6f %.6f %.6f\n", creal(p), cimag(p), creal(q), cimag(q));
  float complex f = 0.5f + 0.5f * I;
  for (int i = 0; i < 5; i++) f = f * f + (0.1f + 0.2f * I);
  printf("%.6f %.6f\n", crealf(f), cimagf(f));
  return 0;
}
