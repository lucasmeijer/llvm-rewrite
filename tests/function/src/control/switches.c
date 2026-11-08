int dense(int x) {
  switch (x) { case 0: return 10; case 1: return 11; case 2: return 13; case 3: return 17; case 4: return 19;
               case 5: return 23; case 6: return 29; case 7: return 31; case 9: return 37; default: return -1; }
}
int sparse(long x) {
  switch (x) { case -5000000000L: return 1; case -1: return 2; case 100: return 3; case 101: return 4; case 4096: return 5;
               case 1L << 40: return 6; default: return 0; }
}
const char *ranges(unsigned char c) {
  switch (c) { case '0' ... '9': return "digit"; case 'a' ... 'z': return "lower"; case 'A' ... 'Z': return "upper";
               case ' ': case '\t': case '\n': return "space"; default: return "other"; }
}
