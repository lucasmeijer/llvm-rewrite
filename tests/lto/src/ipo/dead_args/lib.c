__attribute__((noinline)) int combine(int a, int unused, const int *p, int k) { (void)unused; return a + *p * k; }
__attribute__((noinline)) static int helper(const int *p) { return *p + 1; }
int entry(int x) { int v = x * 2; return combine(x, 99, &v, 3) + helper(&v); }
