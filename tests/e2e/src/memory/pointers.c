#include <stdio.h>
static void swap(int *a, int *b) { int t = *a; *a = *b; *b = t; }
int main(void) {
  int arr[8] = {5, 3, 8, 1, 9, 2, 7, 4};
  for (int i = 0; i < 8; i++)
    for (int j = 0; j + 1 < 8 - i; j++)
      if (arr[j] > arr[j + 1]) swap(&arr[j], &arr[j + 1]);
  int *p = arr, *end = arr + 8;
  long d = end - p;
  while (p < end) printf("%d ", *p++);
  printf("%ld\n", d);
  int **pp = &p;
  *pp = arr + 3;
  printf("%d\n", **pp);
  return 0;
}
