/* SPDX-License-Identifier: MIT
 * Host test for the unlocked linear readback gates and row/pitch copy. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../air/bg_read_unlocked.h"

static void
test_gate(void)
{
   assert(bg_read_unlocked_eligible(1, 0, 1, 0, 0, 1, NULL) == 1);
   assert(bg_read_unlocked_eligible(0, 0, 1, 0, 0, 1, NULL) == 0);
   assert(bg_read_unlocked_eligible(1, 1, 1, 0, 0, 1, NULL) == 0);
   assert(bg_read_unlocked_eligible(1, 0, 4, 0, 0, 1, NULL) == 0);
   assert(bg_read_unlocked_eligible(1, 0, 1, 1, 0, 1, NULL) == 0);
   assert(bg_read_unlocked_eligible(1, 0, 1, 0, 1, 1, NULL) == 0);
   assert(bg_read_unlocked_eligible(1, 0, 1, 0, 0, 0, NULL) == 0);
   assert(bg_read_unlocked_eligible(1, 0, 1, 0, 0, 1, (void *)1) == 0);
}

static void
test_copy(void)
{
   /* 4-byte texels, 3x2 region at (1,1), driver pitch 16, BO offset 8,
    * caller row 12.  Each texel value encodes (row, col) so an offset or pitch
    * mistake is visible rather than accidentally zero. */
   uint8_t bo[256];
   uint8_t dst[64];
   for (unsigned i = 0; i < sizeof(bo); i++) bo[i] = (uint8_t)(0x80 + i);
   for (unsigned i = 0; i < 2; i++)
      for (unsigned j = 0; j < 3; j++) {
         unsigned at = 8 + (1 + i) * 16 + (1 + j) * 4;
         memset(bo + at, (int)(i * 3 + j + 1), 4);
      }
   memset(dst, 0xa5, sizeof(dst));
   assert(bg_copy_linear_rows(dst, 12, bo, 8, 16, 1, 1, 3, 2, 4) == 0);
   for (unsigned i = 0; i < 2; i++)
      for (unsigned j = 0; j < 3; j++) {
         unsigned v = i * 3 + j + 1;
         unsigned at = i * 12 + j * 4;
         assert(dst[at] == v && dst[at + 1] == v && dst[at + 2] == v && dst[at + 3] == v);
      }
   assert(dst[2 * 12] == 0xa5);   /* no fourth row written */
   assert(bg_copy_linear_rows(dst, 12, bo, 8, 8, 1, 1, 3, 2, 4) == -1);
   assert(bg_copy_linear_rows(NULL, 12, bo, 8, 16, 1, 1, 3, 2, 4) == -1);
}

int main(void)
{
   test_gate();
   test_copy();
   puts("PASS: unlocked readback gates and row/pitch copy");
   return 0;
}
