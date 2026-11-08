#include <stdatomic.h>
#include <stdio.h>
static _Thread_local int tls_counter = 7;
static atomic_int shared = 0;
static atomic_long big = 1;
int main(void) {
  for (int i = 0; i < 10; i++) {
    tls_counter += i;
    atomic_fetch_add(&shared, i * 2);
    long expected = atomic_load(&big);
    while (!atomic_compare_exchange_weak(&big, &expected, expected * 3)) {}
  }
  int old = atomic_exchange(&shared, -1);
  printf("%d %d %d %ld\n", tls_counter, old, atomic_load(&shared), atomic_load(&big));
  return 0;
}
