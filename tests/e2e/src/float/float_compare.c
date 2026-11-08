#include <math.h>
#include <stdio.h>
int main(void) {
  double vals[] = {-1.0, 0.0, -0.0, 1.0, INFINITY, NAN};
  for (int i = 0; i < 6; i++)
    for (int j = 0; j < 6; j++) {
      double a = vals[i], b = vals[j];
      printf("%d%d%d%d%d%d", a < b, a <= b, a > b, a >= b, a == b, a != b);
      float fa = (float)a, fb = (float)b;
      printf(" %d%d%d\n", fa < fb, fa == fb, isnan(fa) || isnan(fb));
    }
  return 0;
}
