#include <stdio.h>
int sieve(char *composite, int n, int *last);
static char composite[10001];
int main(void) {
  int last = 0;
  int count = sieve(composite, 10000, &last);
  printf("%d %d\n", count, last);
  return 0;
}
