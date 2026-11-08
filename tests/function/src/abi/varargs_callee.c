#include <stdarg.h>
double vsum(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  double s = 0;
  for (const char *p = fmt; *p; p++) {
    switch (*p) {
    case 'i': s += va_arg(ap, int); break;
    case 'l': s += (double)va_arg(ap, long); break;
    case 'd': s += va_arg(ap, double); break;
    case 'p': s += *va_arg(ap, int *); break;
    }
  }
  va_end(ap);
  return s;
}
static double vinner(int n, va_list ap) { double s = 0; for (int i = 0; i < n; i++) s += va_arg(ap, double) * (i + 1); return s; }
double vforward(int n, ...) { va_list ap; va_start(ap, n); double r = vinner(n, ap); va_end(ap); return r; }
