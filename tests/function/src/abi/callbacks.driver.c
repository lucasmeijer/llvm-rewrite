#include <stdio.h>
typedef long (*binop)(long, long);
typedef double (*dmap)(double);
long fold(const long *, int, long, binop);
double map_sum(const double *, int, dmap);
static long add(long a, long b) { return a + b; }
static long mulmod(long a, long b) { return a * b % 1000003; }
static double sq(double x) { return x * x; }
static double half(double x) { return x / 2; }
int main(void) {
  long xs[20]; double ds[20];
  for (int i = 0; i < 20; i++) { xs[i] = i * 37 - 100; ds[i] = i * 0.75 - 3; }
  printf("%ld %ld %.4f %.4f\n", fold(xs, 20, 0, add), fold(xs, 20, 1, mulmod), map_sum(ds, 20, sq), map_sum(ds, 20, half));
  return 0;
}
