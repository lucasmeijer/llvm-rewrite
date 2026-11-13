#include <string.h>
int cmp_int(const void *a, const void *b) { int x = *(const int *)a, y = *(const int *)b; return (x > y) - (x < y); }
int cmp_str(const void *a, const void *b) { return strcmp(*(const char *const *)a, *(const char *const *)b); }
