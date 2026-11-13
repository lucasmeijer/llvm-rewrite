#include <stdio.h>
long fib(int n); long fact(int n); int is_even(int n);
int main(void) { printf("%ld %ld %d %d\n", fib(20), fact(15), is_even(10), is_even(7)); return 0; }
