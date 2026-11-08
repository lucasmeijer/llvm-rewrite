#include <stdio.h>
static const char *name(int d) {
  switch (d) {
  case 0: return "zero";
  case 1: return "one";
  case 2: return "two";
  case 3: return "three";
  case 4: return "four";
  case 5: return "five";
  case 6: return "six";
  case 7: return "seven";
  default: return "many";
  }
}
int main(void) {
  for (int i = -1; i < 10; i++) printf("%d %s\n", i, name(i));
  return 0;
}
