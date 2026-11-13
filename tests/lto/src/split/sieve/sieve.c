#include <string.h>
int sieve(char *composite, int n, int *last) {
  memset(composite, 0, (size_t)n + 1);
  int count = 0;
  for (int i = 2; i <= n; i++) {
    if (composite[i]) continue;
    count++; *last = i;
    for (int j = i * 2; j <= n; j += i) composite[j] = 1;
  }
  return count;
}
