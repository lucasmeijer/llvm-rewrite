typedef long (*binop)(long, long);
typedef double (*dmap)(double);
long fold(const long *xs, int n, long init, binop f) { long acc = init; for (int i = 0; i < n; i++) acc = f(acc, xs[i]); return acc; }
double map_sum(const double *xs, int n, dmap f) { double s = 0; for (int i = 0; i < n; i++) s += f(xs[i]); return s; }
