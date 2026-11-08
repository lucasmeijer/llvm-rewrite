#include <stdio.h>
int main(void) {
  long total = 0;
  for (int i = 0; i < 20; i++)
    for (int j = i; j < 20; j++)
      for (int k = 0; k < j; k += 2)
        total += i * j - k;
  printf("%ld\n", total);
  int d = 0;
  do { d += 3; } while (d < 100);
  printf("%d\n", d);
  return 0;
}
