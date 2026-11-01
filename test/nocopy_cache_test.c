// SPDX-License-Identifier: MIT
// Host: clang -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined nocopy_cache_test.c -o /tmp/nocopy-cache-test
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/bg_nocopy_cache.h"
int main(int argc, char **argv)
{
   (void)argv;
   unsigned char *source=calloc(1,2*1024*1024+1); assert(source);
   struct bg_nc_cache c[5]={0};
   if(argc>1) {
      setenv("BGMTL_NOCOPY_CACHE","0",1);
      bg_nc_cache_store(&c[0],source,16);assert(!c[0].bytes);
      free(source);puts("no-copy opt-out PASS");return 0;
   }
   bg_nc_cache_store(&c[0],source,16);assert(bg_nc_cache_match(&c[0],source));
   source[16]++;assert(bg_nc_cache_match(&c[0],source)); // allocation padding
   source[15]++;assert(!bg_nc_cache_match(&c[0],source)); // final meaningful byte / mip
   bg_nc_cache_store(&c[0],source,16);assert(bg_nc_cache_match(&c[0],source));
   c[0].valid=0;assert(!bg_nc_cache_match(&c[0],source));
   bg_nc_cache_destroy(&c[0]);assert(!bg_nc_cache_bytes);
   bg_nc_cache_store(&c[0],source,2*1024*1024+1);assert(!c[0].bytes);
   for(unsigned i=0;i<5;i++) bg_nc_cache_store(&c[i],source,2*1024*1024);
   assert(bg_nc_cache_bytes==8*1024*1024 && !c[4].bytes);
   for(unsigned i=0;i<5;i++) bg_nc_cache_destroy(&c[i]);
   assert(!bg_nc_cache_bytes);
   free(source);puts("no-copy mutation, padding, invalidation, memory caps and release PASS");
}
