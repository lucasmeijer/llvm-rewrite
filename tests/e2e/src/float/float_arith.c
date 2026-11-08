#include <stdio.h>
int main(void) {
  float a = 1.25f, b = -3.5f;
  double c = 1e100, d = 3.0;
  printf("%.6f %.6f %.6f %.6f\n", a + b, a - b, a * b, a / b);
  printf("%.6e %.6e %.17g\n", c * d, c / d, 1.0 / 3.0);
  float acc = 0;
  for (int i = 1; i <= 100; i++) acc += 1.0f / i;
  printf("%.7f\n", acc);
  double x = 2.0;
  for (int i = 0; i < 6; i++) x = (x + 2.0 / x) / 2.0;
  printf("%.17g %.6f\n", x, -a);
  return 0;
}
