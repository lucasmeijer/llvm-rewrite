#include <stdio.h>
static int pick(int a, int b) { return a > b ? a - b : b - a; }
int main(void) {
  int t = 0;
  for (int i = -5; i <= 5; i++) {
    int x = (i > 0) && (i % 2 == 0);
    int y = (i < -2) || (i == 3);
    int z = !i;
    t += x * 100 + y * 10 + z + pick(i, 2);
    printf("%d %d %d %d\n", x, y, z, pick(i, 2));
  }
  return t & 0x7f;
}
