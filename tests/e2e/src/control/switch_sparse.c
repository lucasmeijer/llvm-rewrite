#include <stdio.h>
static int f(int x) {
  switch (x) {
  case -1000: return 1;
  case 3: return 2;
  case 77: return 3;
  case 1024: return 4;
  case 65536: return 5;
  case 2000000000: return 6;
  default: return 0;
  }
}
int main(void) {
  int xs[] = {-1000, 3, 4, 77, 1024, 65536, 2000000000, 0, -1};
  int s = 0;
  for (int i = 0; i < 9; i++) { printf("%d\n", f(xs[i])); s = s * 7 + f(xs[i]); }
  return s & 0xff;
}
