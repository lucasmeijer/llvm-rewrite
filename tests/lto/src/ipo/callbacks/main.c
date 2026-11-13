#include <stdio.h>
typedef void (*visit_fn)(int, void *);
void for_each(const int *xs, int n, visit_fn f, void *ctx);
static void sum(int x, void *ctx) { *(long *)ctx += x; }
static void maxv(int x, void *ctx) { if (x > *(int *)ctx) *(int *)ctx = x; }
int main(void) {
  int xs[] = {3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5};
  long s = 0; int m = -1;
  for_each(xs, 11, sum, &s);
  for_each(xs, 11, maxv, &m);
  printf("%ld %d\n", s, m);
  return 0;
}
