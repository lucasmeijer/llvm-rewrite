#include <stdio.h>
static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static int is_even(int n);
static int is_odd(int n) { return n == 0 ? 0 : is_even(n - 1); }
static int is_even(int n) { return n == 0 ? 1 : is_odd(n - 1); }
static unsigned long long fact(unsigned n) { return n ? n * fact(n - 1) : 1; }
int main(void) {
  printf("%d %d %d %llu\n", fib(24), is_even(101), is_odd(77), fact(20));
  return 0;
}
