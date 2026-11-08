double mixed20(int a, double b, char c, float d, long e, double f, short g, float h, int i, double j,
               long k, float l, int m, double n, char o, double p, long q, float r, int s, double t) {
  return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10 + k * 11 + l * 12 + m * 13 +
         n * 14 + o * 15 + p * 16 + q * 17 + r * 18 + s * 19 + t * 20;
}
long ints12(long a, long b, long c, long d, long e, long f, long g, long h, long i, long j, long k, long l) {
  return a - b + c - d + e - f + g - h + i - j + k - l * 3;
}
float floats10(float a, float b, float c, float d, float e, float f, float g, float h, float i, float j) {
  return a + b - c + d - e + f - g + h - i + j * 0.5f;
}
unsigned char small_args(unsigned char a, signed char b, unsigned short c, short d, _Bool e) {
  return (unsigned char)(a + b + c + d + e);
}
