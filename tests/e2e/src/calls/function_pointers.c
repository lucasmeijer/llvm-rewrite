#include <stdio.h>
static int add(int a, int b) { return a + b; }
static int sub(int a, int b) { return a - b; }
static int mul(int a, int b) { return a * b; }
typedef int (*op)(int, int);
static op table[] = {add, sub, mul};
static int apply(op f, int a, int b) { return f(a, b); }
int main(void) {
  int acc = 1;
  for (int i = 0; i < 12; i++) acc = apply(table[i % 3], acc, i + 2);
  printf("%d\n", acc);
  return 0;
}
