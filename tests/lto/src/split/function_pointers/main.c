#include <stdio.h>
typedef int (*op)(int, int);
extern op table[];
int apply(op f, int a, int b);
int main(void) {
  int acc = 1;
  for (int i = 0; i < 12; i++) acc = apply(table[i % 3], acc, i + 2);
  printf("%d\n", acc);
  return 0;
}
