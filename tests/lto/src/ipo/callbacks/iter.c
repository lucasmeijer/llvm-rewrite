typedef void (*visit_fn)(int, void *);
void for_each(const int *xs, int n, visit_fn f, void *ctx) { for (int i = 0; i < n; i++) f(xs[i], ctx); }
