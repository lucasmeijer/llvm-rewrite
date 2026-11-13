#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int cmp_int(const void *a, const void *b);
int cmp_str(const void *a, const void *b);
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
