#include <stdio.h>
#include <string.h>
struct big { long a[20]; char tag[13]; };
static struct big make(int k) {
  struct big b;
  memset(&b, 0, sizeof b);
  for (int i = 0; i < 20; i++) b.a[i] = (long)i * k;
  strcpy(b.tag, "made");
  return b;
}
int main(void) {
  struct big x = make(3);
  struct big y = x;
  y.a[5] = -1;
  char buf[100];
  memset(buf, 'a', sizeof buf);
  memmove(buf + 10, buf, 50);
  buf[99] = 0;
  printf("%ld %ld %s %zu %c\n", x.a[5], y.a[5] + y.a[19], y.tag, strlen(buf), buf[60]);
  return 0;
}
