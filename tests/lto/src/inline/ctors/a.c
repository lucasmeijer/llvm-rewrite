#include <stdio.h>
int n_order;
__attribute__((constructor(150))) static void init_a(void) { printf("a %d\n", n_order++); }
