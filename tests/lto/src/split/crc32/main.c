#include <stdio.h>
#include <string.h>
unsigned crc32(const unsigned char *p, size_t n);
int main(void) {
  const char *s = "The quick brown fox jumps over the lazy dog";
  printf("%08x\n", crc32((const unsigned char *)s, strlen(s)));
  unsigned char buf[256];
  for (int i = 0; i < 256; i++) buf[i] = (unsigned char)(i * 37 + 11);
  printf("%08x\n", crc32(buf, sizeof buf));
  return 0;
}
