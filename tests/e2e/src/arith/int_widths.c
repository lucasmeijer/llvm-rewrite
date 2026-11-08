#include <stdio.h>
int main(void) {
  signed char sc = -100;
  unsigned char uc = 200;
  short ss = -30000;
  unsigned short us = 60000;
  long long ll = -5000000000LL;
  printf("%d %d %d %d\n", sc, uc, ss, us);
  printf("%d %d\n", (signed char)(sc - 100), (unsigned char)(uc + 100));
  printf("%d %d\n", (short)(ss * 2), (unsigned short)(us * 3));
  printf("%lld %d %u\n", ll, (int)ll, (unsigned)ll);
  printf("%lld %llu\n", (long long)sc, (unsigned long long)uc);
  int sum = sc + uc + ss + us;
  return sum & 0xff;
}
