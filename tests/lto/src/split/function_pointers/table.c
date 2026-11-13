typedef int (*op)(int, int);
int add(int, int); int sub(int, int); int mul(int, int);
op table[] = {add, sub, mul};
int apply(op f, int a, int b) { return f(a, b); }
