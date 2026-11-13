#include <stdio.h>
int entry(int x);
int main(void) { int s = 0; for (int i = 0; i < 10; i++) s += entry(i); printf("%d\n", s); return 0; }
