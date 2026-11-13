#include <stdio.h>
#include "table.h"
int main(void) {
  char k[16];
  for (int i = 0; i < 40; i++) { snprintf(k, sizeof k, "key%d", i * 13); put(k, i * i); }
  put("key13", -5);
  long s = 0;
  for (int i = 0; i < 60; i++) { snprintf(k, sizeof k, "key%d", i * 13); s += get(k); }
  printf("%ld %d %d\n", s, get("key13"), get("nope"));
  return 0;
}
