#include <stdio.h>
int main(void) {
  int vals[] = {-3, -1, 0, 1, 2, 2147483647};
  for (int i = 0; i < 6; i++)
    for (int j = 0; j < 6; j++) {
      int a = vals[i], b = vals[j];
      unsigned ua = (unsigned)a, ub = (unsigned)b;
      printf("%d%d%d%d%d%d %d%d%d%d\n", a < b, a <= b, a > b, a >= b, a == b, a != b,
             ua < ub, ua <= ub, ua > ub, ua >= ub);
    }
  return 0;
}
