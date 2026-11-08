#include <stdio.h>
struct item { const char *name; int qty; double price; };
static struct item inv[] = {{"apple", 3, 0.5}, {"pear", 10, 0.75}, {"fig", 2, 2.25}, {"kiwi", 7, 0.3}};
static double total(const struct item *it, int n) {
  double t = 0;
  for (int i = 0; i < n; i++) t += it[i].qty * it[i].price;
  return t;
}
int main(void) {
  for (int i = 0; i < 4; i++) inv[i].qty += i;
  printf("%.2f\n", total(inv, 4));
  struct item best = inv[0];
  for (int i = 1; i < 4; i++) if (inv[i].qty * inv[i].price > best.qty * best.price) best = inv[i];
  printf("%s\n", best.name);
  return 0;
}
