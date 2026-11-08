#include <stdio.h>
#include <string.h>
static unsigned crc32(const unsigned char *p, size_t n) {
  unsigned c = 0xffffffffu;
  for (size_t i = 0; i < n; i++) {
    c ^= p[i];
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
  }
  return ~c;
}
int main(void) {
  const char *s = "The quick brown fox jumps over the lazy dog";
  printf("%08x\n", crc32((const unsigned char *)s, strlen(s)));
  unsigned char buf[256];
  for (int i = 0; i < 256; i++) buf[i] = (unsigned char)(i * 37 + 11);
  printf("%08x\n", crc32(buf, sizeof buf));
  return 0;
}
