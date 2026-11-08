#include <stdio.h>
int main(void) {
  printf("[%5d] [%-5d] [%05d] [%+d] [%x] [%X] [%o] [%#x]\n", 42, 42, 42, 42, 255, 255, 8, 255);
  printf("[%c] [%s] [%10s] [%-10s] [%.3s]\n", 'z', "str", "right", "left", "truncate");
  printf("[%f] [%.2f] [%e] [%g] [%g]\n", 3.14159, 2.71828, 12345.678, 0.0001, 1e20);
  printf("[%ld] [%lu] [%lld] [%hhd] [%hd] [%zu] [%%]\n", -1L, 1UL << 40, -(1LL << 62), (char)300, (short)70000, sizeof(long));
  char buf[64];
  int n = snprintf(buf, sizeof buf, "%d-%s-%.1f", 7, "x", 0.25);
  puts(buf);
  return n;
}
