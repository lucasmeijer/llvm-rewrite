#include <stdio.h>
extern int counter;
extern long big;
extern const char greeting[6];
extern int table[5];
extern int *ptr;
int main(void) {
  counter += 10;
  big /= 3;
  *ptr += 1;
  printf("%d %ld %s %d %d %d\n", counter, big, greeting, table[2], table[4], (int)sizeof(greeting));
  return 0;
}
