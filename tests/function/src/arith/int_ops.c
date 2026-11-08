#include <stdint.h>
int8_t add8(int8_t a, int8_t b) { return (int8_t)(a + b); }
uint8_t mul8(uint8_t a, uint8_t b) { return (uint8_t)(a * b); }
int16_t sub16(int16_t a, int16_t b) { return (int16_t)(a - b); }
uint16_t shl16(uint16_t a, int k) { return (uint16_t)(a << k); }
int32_t div32(int32_t a, int32_t b) { return a / b; }
int32_t rem32(int32_t a, int32_t b) { return a % b; }
uint32_t udiv32(uint32_t a, uint32_t b) { return a / b; }
uint32_t urem32(uint32_t a, uint32_t b) { return a % b; }
int32_t ashr32(int32_t a, int k) { return a >> k; }
uint32_t lshr32(uint32_t a, int k) { return a >> k; }
int64_t mul64(int64_t a, int64_t b) { return (int64_t)((uint64_t)a * (uint64_t)b); }
int64_t div64(int64_t a, int64_t b) { return a / b; }
uint64_t udiv64(uint64_t a, uint64_t b) { return a / b; }
uint64_t mix64(uint64_t a, uint64_t b) { return (a ^ (b << 13)) + (a >> 7) - (b | 0x1234); }
int cmp_signed(int64_t a, int64_t b) { return (a < b) * 4 + (a == b) * 2 + (a > b); }
int cmp_unsigned(uint32_t a, uint32_t b) { return (a < b) * 4 + (a == b) * 2 + (a > b); }
