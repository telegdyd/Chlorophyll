/* SPDX-License-Identifier: MIT */
/* Fresh process per combination: all UBWC environment options are read once.
 * argv: isolated-dir ubwc mrts2 sysmem texbase tileall alignment [--reference] */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv)
{
   if (argc < 8 || argc > 9 || argv[1][0] != '/' ||
       (argc == 9 && strcmp(argv[8], "--reference"))) return 2;
   const char *names[] = {"BGMTL_UBWC", "FD5_UBWC_MRTS2", "FD5_UBWC_SYSMEM",
      "FD5_UBWC_TEXBASE", "FD5_UBWC_TILEALL", "FD5_UBWC_FLAG_ALIGN"};
   for (int i = 0; i < 6; i++)
      if (setenv(names[i], argv[i + 2], 1)) return 3;
   unsetenv("DYLD_INSERT_LIBRARIES");
   setenv("DYLD_LIBRARY_PATH", argv[1], 1);
   /* Exercise bypass by default; SYSMEM=0 must override it for UBWC. */
   setenv("FD_MESA_DEBUG", "sysmem", 1);
   setenv("SWEETCA_GMEM", "0", 1);
   unsetenv("BGMTL_BB");
   unsetenv("BGMTL_ASYNC");
   unsetenv("BGMTL_SHADOW");
   if (chdir(argv[1])) { perror("chdir"); return 3; }
   char binary[512], library[512];
   if (snprintf(binary, sizeof(binary), "%s/bgmtl_ubwc_probe", argv[1]) >= (int)sizeof(binary) ||
       snprintf(library, sizeof(library), "%s/bg_ubwc.metallib", argv[1]) >= (int)sizeof(library))
      return 2;
   char *args[] = {binary, library, argc == 9 ? argv[8] : NULL, NULL};
   execv(binary, args);
   perror("execv"); return 3;
}
