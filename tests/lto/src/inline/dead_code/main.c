#include <stdio.h>
int used_value(int x);
extern int lib_state;
int main(int argc, char **argv) {
  (void)argv;
  printf("%d %d\n", used_value(argc + 4), lib_state);
  return 0;
}
