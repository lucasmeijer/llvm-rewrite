float fadd(float a, float b) { return a + b; }
float fmul(float a, float b) { return a * b; }
double ddiv(double a, double b) { return a / b; }
double dsub(double a, double b) { return a - b; }
double fma_like(double a, double b, double c) { return a * b + c; }
int fcmp_all(double a, double b) { return (a < b) | (a <= b) << 1 | (a > b) << 2 | (a >= b) << 3 | (a == b) << 4 | (a != b) << 5; }
double neg(double a) { return -a; }
float to_float(double a) { return (float)a; }
double to_double(float a) { return a; }
int d2i(double a) { return (int)a; }
long long d2ll(double a) { return (long long)a; }
unsigned d2u(double a) { return (unsigned)a; }
double i2d(int a) { return a; }
double u2d(unsigned a) { return a; }
double ull2d(unsigned long long a) { return (double)a; }
float ll2f(long long a) { return (float)a; }
