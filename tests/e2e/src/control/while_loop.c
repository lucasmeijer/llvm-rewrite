int main(void) {
  int n = 27, steps = 0;
  while (n != 1) {
    n = (n % 2) ? 3 * n + 1 : n / 2;
    steps++;
  }
  return steps; /* 111 */
}
