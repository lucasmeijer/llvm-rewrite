#include <inttypes.h>
#include <stdio.h>
int8_t add8(int8_t, int8_t); uint8_t mul8(uint8_t, uint8_t); int16_t sub16(int16_t, int16_t);
uint16_t shl16(uint16_t, int); int32_t div32(int32_t, int32_t); int32_t rem32(int32_t, int32_t);
uint32_t udiv32(uint32_t, uint32_t); uint32_t urem32(uint32_t, uint32_t); int32_t ashr32(int32_t, int);
uint32_t lshr32(uint32_t, int); int64_t mul64(int64_t, int64_t); int64_t div64(int64_t, int64_t);
uint64_t udiv64(uint64_t, uint64_t); uint64_t mix64(uint64_t, uint64_t); int cmp_signed(int64_t, int64_t);
int cmp_unsigned(uint32_t, uint32_t);
static const int64_t V[] = {0, 1, -1, 2, -2, 7, -7, 127, -128, 255, 32767, -32768, 65535, 2147483647, -2147483647 - 1,
                            4294967295LL, 1000000007, -999999999999LL, INT64_MAX, INT64_MIN};
#define NV (int)(sizeof V / sizeof V[0])
int main(void) {
  for (int i = 0; i < NV; i++)
    for (int j = 0; j < NV; j++) {
      int64_t a = V[i], b = V[j];
      printf("%d %d %d %u", add8((int8_t)a, (int8_t)b), mul8((uint8_t)a, (uint8_t)b), sub16((int16_t)a, (int16_t)b), shl16((uint16_t)a, j % 16));
      int32_t a32 = (int32_t)a, b32 = (int32_t)b;
      if (b32 != 0 && !(a32 == INT32_MIN && b32 == -1)) printf(" %d %d", div32(a32, b32), rem32(a32, b32));
      if ((uint32_t)b != 0) printf(" %u %u", udiv32((uint32_t)a, (uint32_t)b), urem32((uint32_t)a, (uint32_t)b));
      printf(" %d %u %" PRId64, ashr32(a32, j % 32), lshr32((uint32_t)a, j % 32), mul64(a, b));
      if (b != 0 && !(a == INT64_MIN && b == -1)) printf(" %" PRId64, div64(a, b));
      if (b != 0) printf(" %" PRIu64, udiv64((uint64_t)a, (uint64_t)b));
      printf(" %" PRIu64 " %d %d\n", mix64((uint64_t)a, (uint64_t)b), cmp_signed(a, b), cmp_unsigned((uint32_t)a, (uint32_t)b));
    }
  return 0;
}
