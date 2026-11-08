#include <stdio.h>
static int run(const unsigned char *code) {
  static void *ops[] = {&&op_inc, &&op_dbl, &&op_dec, &&op_halt};
  int acc = 0, pc = 0;
  goto *ops[code[pc++]];
op_inc: acc += 1; goto *ops[code[pc++]];
op_dbl: acc *= 2; goto *ops[code[pc++]];
op_dec: acc -= 3; goto *ops[code[pc++]];
op_halt: return acc;
}
int main(void) {
  const unsigned char prog[] = {0, 0, 1, 1, 0, 2, 1, 0, 1, 3};
  printf("%d\n", run(prog));
  return 0;
}
