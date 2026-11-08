#include <stdio.h>
static int f(int n) {
  int vla[n];
  for (int i = 0; i < n; i++) vla[i] = i * 3;
  int s = 0;
  for (int i = 0; i < n; i++) s += vla[n - 1 - i] * i;
  return s;
}
int main(void) {
  int t = 0;
  for (int n = 1; n < 40; n += 5) { t += f(n); printf("%d\n", f(n)); }
  return t & 0xff;
}
