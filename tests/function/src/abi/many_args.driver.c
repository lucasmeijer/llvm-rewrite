#include <stdio.h>
double mixed20(int, double, char, float, long, double, short, float, int, double, long, float, int, double, char, double, long, float, int, double);
long ints12(long, long, long, long, long, long, long, long, long, long, long, long);
float floats10(float, float, float, float, float, float, float, float, float, float);
unsigned char small_args(unsigned char, signed char, unsigned short, short, _Bool);
int main(void) {
  for (int x = -2; x <= 2; x++) {
    printf("%.4f\n", mixed20(x, 1.5, 'a', 2.25f, x * 1000000000L, -3.5, (short)-7, 0.5f, 9, 10.0, 11, 12.5f, 13, 14.0, 'o', 16.0, 17, 18.0f, x, 20.25));
    printf("%ld\n", ints12(x, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 1L << 40));
    printf("%.4f\n", floats10(x, 1, 2, 3, 4, 5, 6, 7, 8, 9.5f));
    printf("%d\n", small_args((unsigned char)(200 + x), (signed char)(-100 + x), (unsigned short)60000, (short)-30000, x > 0));
  }
  return 0;
}
