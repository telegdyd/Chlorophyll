// SPDX-License-Identifier: MIT
// jasmine: the minimal iOS root has no env(1). Supply per-exec test variables.
// Usage: bgmtl_exec 1|0|unset /absolute/test [args...]
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
   if (argc < 3 || argv[2][0] != '/' ||
       (strcmp(argv[1], "1") && strcmp(argv[1], "0") && strcmp(argv[1], "unset"))) {
      fprintf(stderr, "usage: bgmtl_exec 1|0|unset /absolute/test [args...]\n");
      return 2;
   }
   if (setenv("DYLD_INSERT_LIBRARIES", "/usr/local/bin/bgmtl_inject.dylib", 1) ||
       (!strcmp(argv[1], "unset") ? unsetenv("BGMTL_ENABLE") : setenv("BGMTL_ENABLE", argv[1], 1))) {
      perror("test environment");
      return 3;
   }
   execv(argv[2], &argv[2]);
   perror("execv");
   return 4;
}
