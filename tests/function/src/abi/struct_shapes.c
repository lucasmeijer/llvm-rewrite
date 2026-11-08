struct c1 { char a; };
struct c3 { char a, b, c; };
struct sh { short a; char b; };
struct ii { int a, b; };
struct iii { int a, b, c; };
struct ll { long a, b; };
struct lll { long a, b, c; };
struct ff { float a, b; };
struct fff { float a, b, c; };
struct dd { double a, b; };
struct id { int a; double b; };
struct di { double a; int b; };
struct fi { float a; int b; };
struct big { int v[10]; };
int sum_c1(struct c1 s) { return s.a; }
int sum_c3(struct c3 s) { return s.a + s.b * 3 + s.c * 5; }
int sum_sh(struct sh s) { return s.a * 2 + s.b; }
long sum_ii(struct ii s) { return (long)s.a * 7 + s.b; }
long sum_iii(struct iii s) { return s.a + s.b * 2L + s.c * 3L; }
long sum_ll(struct ll s) { return s.a - s.b; }
long sum_lll(struct lll s) { return s.a + s.b * 2 + s.c * 3; }
double sum_ff(struct ff s) { return s.a * 2 + s.b; }
double sum_fff(struct fff s) { return s.a + s.b * 2 + s.c * 3; }
double sum_dd(struct dd s) { return s.a / 2 + s.b; }
double sum_id(struct id s) { return s.a + s.b; }
double sum_di(struct di s) { return s.a * s.b; }
double sum_fi(struct fi s) { return s.a - s.b; }
long sum_big(struct big s) { long t = 0; for (int i = 0; i < 10; i++) t += (long)s.v[i] * (i + 1); return t; }
struct c3 mk_c3(int x) { struct c3 s = {(char)x, (char)(x + 1), (char)(x + 2)}; return s; }
struct iii mk_iii(int x) { struct iii s = {x, -x, x * 3}; return s; }
struct lll mk_lll(long x) { struct lll s = {x, x * (1L << 20), ~x}; return s; }
struct fff mk_fff(float x) { struct fff s = {x, x * 2, x * 4}; return s; }
struct dd mk_dd(double x) { struct dd s = {x, -x}; return s; }
struct id mk_id(int x) { struct id s = {x, x / 4.0}; return s; }
struct di mk_di(double x) { struct di s = {x, (int)x * 2}; return s; }
struct big mk_big(int x) { struct big s; for (int i = 0; i < 10; i++) s.v[i] = x * i; return s; }
double many(struct ii a, struct dd b, struct lll c, struct fi d, struct ff e, struct id f, struct ll g, struct dd h, struct ii i) {
  return a.a + a.b + b.a + b.b + c.a + c.b + c.c + d.a + d.b + e.a + e.b + f.a + f.b + g.a + g.b + h.a + h.b + i.a + i.b;
}
