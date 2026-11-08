#include <stdio.h>
struct point { int x, y; };
struct rect { struct point tl, br; char tag; };
static int area(const struct rect *r) { return (r->br.x - r->tl.x) * (r->br.y - r->tl.y); }
int main(void) {
  struct rect r = {{1, 2}, {11, 7}, 'r'};
  struct rect copy = r;
  copy.br.x += 5;
  printf("%d %d %c %zu\n", area(&r), area(&copy), copy.tag, sizeof(struct rect));
  return 0;
}
