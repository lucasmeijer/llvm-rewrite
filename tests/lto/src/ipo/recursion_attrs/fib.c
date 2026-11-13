long fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
long fact(int n) { return n <= 1 ? 1 : n * fact(n - 1); }
int is_even(int n);
int is_odd(int n) { return n == 0 ? 0 : is_even(n - 1); }
