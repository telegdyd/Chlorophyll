/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <stdio.h>
#include "../air/bg_ubwc.h"
#include "fd5_ubwc_layout.h"
#include "fd5_ubwc_eligible.h"

int main(void)
{
   /* Values independently calculated from the documented block dimensions.
    * The first case is the blob example, including its 512-byte color pitch. */
   const unsigned cases[][5] = {
      {100,2000,64,512,0x8000}, {1,1,64,16,4096},
      {1024,64,64,16,4096}, {1025,65,128,32,4096},
      {828,1792,64,448,28672}, {1271,1823,128,464,61440},
   };
   for (unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
      const unsigned *c=cases[i];
      assert(fd5_ubwc_meta_pitch(c[0])==c[2]);
      assert(fd5_ubwc_meta_height(c[1])==c[3]);
      assert(fd5_ubwc_meta_size(c[0],c[1],4096)==c[4]);
   }
   assert(fd5_ubwc_meta_size(100,2000,65536)==65536);
   /* Whole blob allocation (single level): flags first; normal fd5 TILE5_3
    * pitch ALIGN(width,64)*4, height ALIGN(height,16), page-aligned layer. */
   unsigned flags=fd5_ubwc_meta_size(100,2000,4096);
   unsigned pitch=((100+63)&~63u)*4, color=pitch*((2000+15)&~15u);
   unsigned layer=(flags+color+4095)&~4095u;
   assert(flags==0x8000 && pitch==512 && layer==0x102000);
   for (unsigned w=1;w<2048;w+=17) for (unsigned h=1;h<2048;h+=31) {
      unsigned p=fd5_ubwc_meta_pitch(w), y=fd5_ubwc_meta_height(h);
      unsigned s=fd5_ubwc_meta_size(w,h,4096);
      assert(p%64==0 && p>=(w+15)/16 && y%16==0 && y>=(h+3)/4);
      assert(s%4096==0 && s>=p*y && s-p*y<4096);
   }
   assert(fd5_ubwc_eligible(true,true,true,1,1,0,0,0,false,false,false));
   assert(fd5_ubwc_eligible(true,true,true,1,1,0,1,1,false,false,false));
   /* Every restriction is independently fatal. */
   for(unsigned i=0;i<11;i++)
      assert(!fd5_ubwc_eligible(i!=0,i!=1,i!=2,i==3?2:1,i==4?2:1,
         i==5?1:0,i==6?2:1,i==7?2:1,i==8,i==9,i==10));
   assert(bg_ubwc_eligible(70,2,1,1,1,1,5,true,false));
   assert(bg_ubwc_eligible(80,2,1,1,1,1,4,true,false));
   for(unsigned i=0;i<10;i++)
      assert(!bg_ubwc_eligible(i==0?71:80,i==1?3:2,i==2?2:1,
         i==3?2:1,i==4?2:1,i==5?2:1,i==6?1:i==7?7:5,i!=8,i==9));
   puts("UBWC layout and eligibility PASS");
   return 0;
}
