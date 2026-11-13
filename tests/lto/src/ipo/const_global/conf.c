int mode = 2;
static int calls;
int get_mode(void) { calls++; return mode; }
int get_calls(void) { return calls; }
