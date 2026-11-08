int main(void) {
  int a = 100, b = 58, c = -7;
  int r = a - b + c;      /* 35 */
  r = r + (a + b) / 2;    /* 35 + 79 = 114 */
  return r - 100;         /* 14 */
}
