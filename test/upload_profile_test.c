// SPDX-License-Identifier: MIT
// Host-only bounds/accounting regression for the opt-in upload inventory.
// clang -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined upload_profile_test.c -o /tmp/upload-profile-test
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
struct rwa_texture_shape { unsigned width, height, pixel_format, mip_levels; };
struct rwa_texture { size_t row[2]; unsigned rows[2]; };
static int rwa_texture_upload_layout(struct rwa_texture *t, unsigned l, size_t *row, unsigned *rows)
{ if (l >= 2) return -1; *row=t->row[l]; *rows=t->rows[l]; return 0; }
#define BG_LOG(...) ((void)0)
static FILE *test_open(const char *path, const char *mode) { (void)path; (void)mode; return tmpfile(); }
#define fopen test_open
#include "../src/bg_upload_profile.h"
#undef fopen
int main(void)
{
   setenv("BGMTL_UPLOAD_PROFILE", "1", 1);
   bg_upload_begin(); // no trigger: stays inactive
   assert(!bg_upload.active);
   bg_upload.active=1; bg_upload.deadline=UINT64_MAX;
   struct rwa_texture t={{4,2},{2,1}};
   struct rwa_texture_shape shape={4,2,10,1};
   uint8_t bytes[12]={1,2,3,4,9,9,9,9,5,6,7,8};
   uint64_t id=0;
   bg_upload_note(&id,1,0,&t,&shape,bytes,bytes,sizeof(bytes),0,8,0);
   assert(bg_upload.record[0].first==1 && bg_upload.frame[0].bytes==8);
   bytes[4]++; // row padding must not affect the hash
   bg_upload_note(&id,2,0,&t,&shape,bytes,bytes,sizeof(bytes),0,8,0);
   assert(bg_upload.record[0].same_hash==1);
   bytes[0]++;
   bg_upload_note(&id,3,0,&t,&shape,bytes,bytes,sizeof(bytes),0,8,0);
   assert(bg_upload.record[0].changed==1);
   bg_upload_note(&id,3,0,&t,&shape,bytes,NULL,0,0,8,1);
   bg_upload_note(&id,3,0,&t,&shape,bytes,NULL,0,0,8,-1);
   assert(bg_upload.frame[0].skipped==1 && bg_upload.frame[0].failed==1);
   bg_upload_note(&id,3,0,&t,&shape,bytes,bytes,sizeof(bytes),0,8,2);
   assert(bg_upload.frame[0].content_reuses==1 && bg_upload.frame[0].reused_bytes==8);
   assert(bg_upload.record[0].writes==3 && bg_upload.record[0].commits==1);
   bg_upload_end();
   shape.mip_levels=2;
   uint64_t packed=0;
   bg_upload_note(&packed,4,1,&t,&shape,bytes,bytes,10,0,0,0);
   assert(bg_upload.frame[1].bytes==10 && bg_upload.record[1].unknown==1);
   bg_upload_note(&packed,5,1,&t,&shape,bytes,bytes,10,0,0,0);
   assert(bg_upload.record[1].same_hash==1);
   bytes[9]++;
   bg_upload_note(&packed,6,1,&t,&shape,bytes,bytes,10,0,0,0);
   assert(bg_upload.record[1].changed==1);
   // Truncated source must not be read, or compared to an old hash later.
   bg_upload_note(&packed,7,1,&t,&shape,bytes,bytes,1,0,0,0);
   assert(!bg_upload.record[1].have_hash);
   bg_upload.hash_bytes=268435456ull;
   bg_upload_note(&packed,8,1,&t,&shape,bytes,bytes,10,0,0,0);
   assert(!bg_upload.record[1].have_hash);
   for(unsigned i=2;i<BG_UPLOAD_RECORDS+1;i++) {
      uint64_t next=0;
      bg_upload_note(&next,1,1,&t,&shape,bytes,bytes,10,0,0,0);
   }
   assert(bg_upload.count==BG_UPLOAD_RECORDS && bg_upload.overflow==1);
   while(!bg_upload.finished) bg_upload_end();
   uint64_t count=bg_upload.frame[119].writes;
   bg_upload_note(&id,9,0,&t,&shape,bytes,bytes,sizeof(bytes),0,8,0);
   assert(bg_upload.frame[119].writes==count && !bg_upload.active);
   puts("upload inventory: padding, mip chain, mutation, bounds, budget, overflow and stop PASS");
}
