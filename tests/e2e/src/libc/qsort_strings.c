#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int cmp_int(const void *a, const void *b) { int x = *(const int *)a, y = *(const int *)b; return (x > y) - (x < y); }
static int cmp_str(const void *a, const void *b) { return strcmp(*(const char *const *)a, *(const char *const *)b); }
int main(void) {
  int xs[] = {42, -7, 19, 0, 1000, 3, 3, -100, 55};
  qsort(xs, 9, sizeof xs[0], cmp_int);
  for (int i = 0; i < 9; i++) printf("%d ", xs[i]);
  printf("\n");
  const char *words[] = {"pear", "apple", "fig", "banana", "cherry", "date"};
  qsort(words, 6, sizeof words[0], cmp_str);
  for (int i = 0; i < 6; i++) printf("%s ", words[i]);
  printf("\n");
  char s[32] = "hello";
  strcat(s, ", world");
  char *p = strchr(s, 'w');
  printf("%s %zu %ld %d\n", s, strlen(s), p - s, memcmp("abc", "abd", 3) < 0);
  return 0;
}
