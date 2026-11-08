int classify(int x) {
  if (x < 0) return 1;
  else if (x == 0) return 2;
  else if (x < 10) return 3;
  return 4;
}
int main(void) {
  return classify(-5) + classify(0) * 10 + classify(7) * 100 % 256 + classify(99);
}
