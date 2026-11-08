int main(void) {
  int a[16];
  for (int i = 0; i < 16; i++) a[i] = i * i;
  int s = 0;
  for (int i = 15; i >= 0; i -= 2) s += a[i];
  return s % 256;
}
