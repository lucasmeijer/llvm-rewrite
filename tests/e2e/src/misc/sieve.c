#include <stdio.h>
#include <string.h>
int main(void) {
  static char composite[10001];
  memset(composite, 0, sizeof composite);
  int count = 0, last = 0;
  for (int i = 2; i <= 10000; i++) {
    if (composite[i]) continue;
    count++; last = i;
    for (int j = i * 2; j <= 10000; j += i) composite[j] = 1;
  }
  printf("%d %d\n", count, last);
  return 0;
}
