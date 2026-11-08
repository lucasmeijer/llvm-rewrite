// rss <cmd...>: runs cmd (stdout/stderr to /dev/null) and prints "<peak RSS KiB> <cpu s> <exit code>".
// Forked from this small process, so ru_maxrss is the tool's own (the harness's wait4 from a big Python
// process reports the parent's RSS when that is larger; NOTES.md). Build: cc -O2 -o /tmp/rss tools/rss.c
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <stdlib.h>
int main(int c, char **v) {
  pid_t p = fork();
  if (!p) { int fd = open("/dev/null", 1); dup2(fd,1); dup2(fd,2); execvp(v[1], v + 1); _exit(127); }
  int st; struct rusage ru; wait4(p, &st, 0, &ru);
  printf("%ld %.3f %d\n", ru.ru_maxrss, ru.ru_utime.tv_sec + ru.ru_utime.tv_usec/1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec/1e6, WEXITSTATUS(st));
  return 0;
}
