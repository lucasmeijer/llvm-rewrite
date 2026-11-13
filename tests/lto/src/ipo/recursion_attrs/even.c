int is_odd(int n);
int is_even(int n) { return n == 0 ? 1 : is_odd(n - 1); }
