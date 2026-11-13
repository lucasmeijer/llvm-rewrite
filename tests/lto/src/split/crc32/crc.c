#include <stddef.h>
unsigned crc32(const unsigned char *p, size_t n) {
  unsigned c = 0xffffffffu;
  for (size_t i = 0; i < n; i++) {
    c ^= p[i];
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
  }
  return ~c;
}
