/* SPDX-License-Identifier: MIT
 * Host test for the M9 timeline DRAM packing: round-trip surface fields,
 * clamps, and blit class packing. */
#include <assert.h>
#include <stdio.h>
#include "../src/bg_tl_dram.h"

int main(void)
{
   uint64_t a = bg_tl_dram_pack_surface(17, 1, 2, 1, 3, 4, 8, 1920, 1080);
   unsigned pass, role, cls, load, store, samples, bpp, width, height;
   bg_tl_dram_unpack_surface(a, &pass, &role, &cls, &load, &store, &samples,
                             &bpp, &width, &height);
   assert(pass == 17 && role == 1 && cls == 2 && load == 1 && store == 3);
   assert(samples == 4 && bpp == 8 && width == 1920 && height == 1080);

   a = bg_tl_dram_pack_surface(0xfff, 3, 3, 3, 3, 15, 255, 9000, 9000);
   bg_tl_dram_unpack_surface(a, &pass, &role, &cls, &load, &store, &samples,
                             &bpp, &width, &height);
   assert(pass == 0xfff && role == 3 && cls == 3 && width == 0x1fff && height == 0x1fff);

   uint64_t b = bg_tl_dram_pack_blit(5, 2, 1);
   assert((b & 15) == 5 && ((b >> 4) & 3) == 2 && ((b >> 6) & 3) == 1);
   puts("PASS: M9 DRAM packing round-trips and clamps; blit classes pack");
   return 0;
}
