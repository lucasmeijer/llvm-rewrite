#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CAP 64
struct entry { char key[16]; int value; int used; };
static struct entry table[CAP];
static unsigned hash(const char *s) { unsigned h = 5381; while (*s) h = h * 33 + (unsigned char)*s++; return h; }
static void put(const char *k, int v) {
  unsigned i = hash(k) % CAP;
  while (table[i].used && strcmp(table[i].key, k)) i = (i + 1) % CAP;
  strcpy(table[i].key, k); table[i].value = v; table[i].used = 1;
}
static int get(const char *k) {
  unsigned i = hash(k) % CAP;
  while (table[i].used) { if (!strcmp(table[i].key, k)) return table[i].value; i = (i + 1) % CAP; }
  return -1;
}
int main(void) {
  char k[16];
  for (int i = 0; i < 40; i++) { snprintf(k, sizeof k, "key%d", i * 13); put(k, i * i); }
  put("key13", -5);
  long s = 0;
  for (int i = 0; i < 60; i++) { snprintf(k, sizeof k, "key%d", i * 13); s += get(k); }
  printf("%ld %d %d\n", s, get("key13"), get("nope"));
  return 0;
}
