#include <stdio.h>
struct c1 { char a; }; struct c3 { char a, b, c; }; struct sh { short a; char b; }; struct ii { int a, b; };
struct iii { int a, b, c; }; struct ll { long a, b; }; struct lll { long a, b, c; }; struct ff { float a, b; };
struct fff { float a, b, c; }; struct dd { double a, b; }; struct id { int a; double b; }; struct di { double a; int b; };
struct fi { float a; int b; }; struct big { int v[10]; };
int sum_c1(struct c1); int sum_c3(struct c3); int sum_sh(struct sh); long sum_ii(struct ii); long sum_iii(struct iii);
long sum_ll(struct ll); long sum_lll(struct lll); double sum_ff(struct ff); double sum_fff(struct fff); double sum_dd(struct dd);
double sum_id(struct id); double sum_di(struct di); double sum_fi(struct fi); long sum_big(struct big);
struct c3 mk_c3(int); struct iii mk_iii(int); struct lll mk_lll(long); struct fff mk_fff(float); struct dd mk_dd(double);
struct id mk_id(int); struct di mk_di(double); struct big mk_big(int);
double many(struct ii, struct dd, struct lll, struct fi, struct ff, struct id, struct ll, struct dd, struct ii);
int main(void) {
  for (int x = -3; x <= 3; x++) {
    struct c1 c1 = {(char)(x * 40)}; struct c3 c3 = {(char)x, 2, (char)-x}; struct sh sh = {(short)(x * 1000), 9};
    struct ii ii = {x, x * x}; struct iii iii = {x, 5, -7}; struct ll ll = {x * 100000000000L, 3}; struct lll lll = {x, 2, 3};
    struct ff ff = {x * 0.5f, 1.25f}; struct fff fff = {x, 0.5f, 0.25f}; struct dd dd = {x * 1.5, 0.125};
    struct id id = {x, 0.75}; struct di di = {x * 2.5, 3}; struct fi fi = {x * 0.25f, 11};
    struct big big; for (int i = 0; i < 10; i++) big.v[i] = x + i;
    printf("%d %d %d %ld %ld %ld %ld %.4f %.4f %.4f %.4f %.4f %.4f %ld\n", sum_c1(c1), sum_c3(c3), sum_sh(sh), sum_ii(ii),
           sum_iii(iii), sum_ll(ll), sum_lll(lll), sum_ff(ff), sum_fff(fff), sum_dd(dd), sum_id(id), sum_di(di), sum_fi(fi), sum_big(big));
    struct c3 r1 = mk_c3(x); struct iii r2 = mk_iii(x); struct lll r3 = mk_lll(x); struct fff r4 = mk_fff((float)x);
    struct dd r5 = mk_dd(x / 3.0); struct id r6 = mk_id(x); struct di r7 = mk_di(x * 1.25); struct big r8 = mk_big(x);
    printf("  %d %d %d | %d %d %d | %ld %ld %ld | %.3f %.3f %.3f | %.4f %.4f | %d %.3f | %.3f %d | %d %d\n", r1.a, r1.b, r1.c,
           r2.a, r2.b, r2.c, r3.a, r3.b, r3.c, r4.a, r4.b, r4.c, r5.a, r5.b, r6.a, r6.b, r7.a, r7.b, r8.v[0], r8.v[9]);
    printf("  %.4f\n", many(ii, dd, lll, fi, ff, id, ll, dd, ii));
  }
  return 0;
}
