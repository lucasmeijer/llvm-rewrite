#include <stdio.h>
int main(void) {
  int xs[] = {17, -17, 1000003, -5, 0, 2147483647};
  int ds[] = {3, -3, 7, 1, -1, 100};
  for (int i = 0; i < 6; i++)
    for (int j = 0; j < 6; j++) {
      int x = xs[i], d = ds[j];
      if (x == -2147483647 - 1 && d == -1) continue;
      printf("%d %d: %lld %d %d\n", x, d, (long long)x * d / 3, x / d, x % d);
    }
  unsigned u = 4000000000u;
  printf("%u %u %u\n", u / 7u, u % 7u, u * 3u);
  return 0;
}
