#include <stdio.h>
static int next_id(void) { static int id = 100; return id++; }
int main(void) {
  volatile int v = 3;
  int s = 0;
  for (int i = 0; i < 5; i++) { v = v * 2; s += next_id() + v; }
  printf("%d %d\n", s, v);
  return 0;
}
