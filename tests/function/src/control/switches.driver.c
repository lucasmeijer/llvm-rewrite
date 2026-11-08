#include <stdio.h>
int dense(int); int sparse(long); const char *ranges(unsigned char);
int main(void) {
  for (int i = -3; i < 14; i++) printf("%d ", dense(i));
  printf("\n");
  long xs[] = {-5000000000L, -1, 0, 100, 101, 102, 4096, 1L << 40, (1L << 40) + 1};
  for (int i = 0; i < 9; i++) printf("%d ", sparse(xs[i]));
  printf("\n");
  for (int c = 0; c < 256; c += 3) printf("%s%c", ranges((unsigned char)c), c % 48 == 0 ? '\n' : ' ');
  printf("\n");
  return 0;
}
