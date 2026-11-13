#include <stdio.h>
int config_value(void);
int config_other(void);
extern int weak_data;
int main(void) {
  printf("%d %d %d\n", config_value(), config_other(), weak_data);
  return 0;
}
