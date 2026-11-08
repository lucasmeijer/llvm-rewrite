#include <stdio.h>
int counter = 5;
static long big = 1234567890123L;
const char greeting[] = "hello";
int table[5] = {10, 20, 30};
static int *ptr = &table[2];
int main(void) {
  counter += 10;
  big /= 3;
  *ptr += 1;
  printf("%d %ld %s %d %d %d\n", counter, big, greeting, table[2], table[4], (int)sizeof(greeting));
  return 0;
}
