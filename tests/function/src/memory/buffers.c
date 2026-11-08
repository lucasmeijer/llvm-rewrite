#include <stddef.h>
void reverse(int *a, size_t n) { for (size_t i = 0, j = n ? n - 1 : 0; i < j; i++, j--) { int t = a[i]; a[i] = a[j]; a[j] = t; } }
long dot(const short *a, const short *b, int n) { long s = 0; for (int i = 0; i < n; i++) s += a[i] * b[i]; return s; }
void prefix_sum(double *a, int n) { for (int i = 1; i < n; i++) a[i] += a[i - 1]; }
size_t count_byte(const unsigned char *p, size_t n, unsigned char c) { size_t k = 0; while (n--) k += *p++ == c; return k; }
void transpose4(float m[4][4]) { for (int i = 0; i < 4; i++) for (int j = i + 1; j < 4; j++) { float t = m[i][j]; m[i][j] = m[j][i]; m[j][i] = t; } }
struct pair { int key; long val; };
long find(const struct pair *ps, int n, int key) { for (int i = 0; i < n; i++) if (ps[i].key == key) return ps[i].val; return -1; }
