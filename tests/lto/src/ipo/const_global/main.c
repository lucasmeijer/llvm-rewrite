#include <stdio.h>
int get_mode(void); int get_calls(void);
int main(void) {
  long s = 0;
  for (int i = 0; i < 1000; i++) s += get_mode() == 2 ? i : -i;
  printf("%ld %d\n", s, get_calls());
  return 0;
}
