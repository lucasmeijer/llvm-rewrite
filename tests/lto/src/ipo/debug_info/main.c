#include <stdio.h>
struct point { int x, y; };
int manhattan(struct point a, struct point b);
int main(void) {
  struct point o = {0, 0};
  int total = 0;
  for (int i = 0; i < 5; i++) { struct point p = {i * 3, -i}; total += manhattan(o, p); }
  printf("%d\n", total);
  return 0;
}
