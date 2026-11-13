#include <string.h>
#include "table.h"
#define CAP 64
struct entry { char key[16]; int value; int used; };
static struct entry table[CAP];
static unsigned hash(const char *s) { unsigned h = 5381; while (*s) h = h * 33 + (unsigned char)*s++; return h; }
void put(const char *k, int v) {
  unsigned i = hash(k) % CAP;
  while (table[i].used && strcmp(table[i].key, k)) i = (i + 1) % CAP;
  strcpy(table[i].key, k); table[i].value = v; table[i].used = 1;
}
int get(const char *k) {
  unsigned i = hash(k) % CAP;
  while (table[i].used) { if (!strcmp(table[i].key, k)) return table[i].value; i = (i + 1) % CAP; }
  return -1;
}
