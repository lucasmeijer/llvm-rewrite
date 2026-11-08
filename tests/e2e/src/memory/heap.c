#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct node { int v; struct node *next; };
int main(void) {
  struct node *head = NULL;
  for (int i = 0; i < 50; i++) {
    struct node *n = malloc(sizeof *n);
    n->v = i * 7 % 13;
    n->next = head;
    head = n;
  }
  long s = 0; int cnt = 0;
  for (struct node *n = head; n; n = n->next) { s += n->v * ++cnt; }
  while (head) { struct node *n = head->next; free(head); head = n; }
  char *buf = calloc(64, 1);
  memset(buf, 'x', 10);
  strcpy(buf + 10, "-tail");
  printf("%ld %s %zu\n", s, buf, strlen(buf));
  free(buf);
  return 0;
}
