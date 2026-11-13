#include <stdio.h>
int used_value(int x) { return x * 3 + 1; }
int unused_value(int x) { return x * x * x - 7; }
void unused_print(const char *s) { printf("unused %s\n", s); }
int lib_state = 42;
int unused_state[100] = {1, 2, 3};
