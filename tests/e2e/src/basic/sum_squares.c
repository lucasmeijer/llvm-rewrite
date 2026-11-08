#include <stdio.h>

static int square(int x) { return x * x; }

int main(void) {
  int sum = 0;
  for (int i = 0; i < 10; i++)
    sum += square(i);
  printf("%d\n", sum);
  return 0;
}
