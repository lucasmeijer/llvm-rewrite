#include <stdio.h>
static int calls;
static int t(int v) { calls++; return v; }
int main(void) {
  int r = 0;
  for (int i = 0; i < 8; i++) {
    int a = i & 1, b = (i >> 1) & 1, c = (i >> 2) & 1;
    r += (t(a) && t(b)) || t(c);
    r += (t(a) || t(b)) && !t(c);
  }
  printf("%d %d\n", r, calls);
  return 0;
}
