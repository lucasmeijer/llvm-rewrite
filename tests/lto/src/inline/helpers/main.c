#include <stdio.h>
struct vec { double x, y, z; };
double dot(const struct vec *a, const struct vec *b);
void scale(struct vec *v, double k);
void add(struct vec *r, const struct vec *a, const struct vec *b);
int main(void) {
  struct vec acc = {0, 0, 0};
  for (int i = 0; i < 100; i++) {
    struct vec v = {i, i * 0.5, -i};
    scale(&v, 1.0 / (i + 1));
    add(&acc, &acc, &v);
  }
  printf("%.6f %.6f %.6f %.6f\n", acc.x, acc.y, acc.z, dot(&acc, &acc));
  return 0;
}
