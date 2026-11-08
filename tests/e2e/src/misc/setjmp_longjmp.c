#include <setjmp.h>
#include <stdio.h>
static jmp_buf env;
static int depth;
static void dive(int n) { depth = n; if (n == 7) longjmp(env, n * 6); dive(n + 1); }
int main(void) {
  int r = setjmp(env);
  if (r == 0) { dive(0); return 1; }
  printf("%d %d\n", r, depth);
  return 0;
}
