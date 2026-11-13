#include <stdio.h>
extern int n_order;
__attribute__((constructor(200))) static void init_b(void) { printf("b %d\n", n_order++); }
__attribute__((constructor(101))) static void init_b2(void) { printf("b2 %d\n", n_order++); }
__attribute__((destructor)) static void fini_b(void) { printf("fini %d\n", n_order); }
