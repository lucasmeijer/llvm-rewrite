#include <stdio.h>
#define N 12
static double a[N][N], b[N][N], c[N][N];
int main(void) {
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) { a[i][j] = i + j * 0.5; b[i][j] = (i == j) ? 2.0 : 0.25; }
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) {
      double s = 0;
      for (int k = 0; k < N; k++) s += a[i][k] * b[k][j];
      c[i][j] = s;
    }
  double tr = 0;
  for (int i = 0; i < N; i++) tr += c[i][i];
  printf("%.3f %.3f\n", tr, c[3][7]);
  return 0;
}
