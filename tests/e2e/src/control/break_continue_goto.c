#include <stdio.h>
int main(void) {
  int s = 0;
  for (int i = 0; i < 100; i++) {
    if (i % 3 == 0) continue;
    if (i > 50) break;
    s += i;
  }
  printf("%d\n", s);
  int i = 0, j;
  for (i = 0; i < 10; i++)
    for (j = 0; j < 10; j++)
      if (i * j == 42) goto found;
  return 1;
found:
  printf("%d %d\n", i, j);
  return 0;
}
