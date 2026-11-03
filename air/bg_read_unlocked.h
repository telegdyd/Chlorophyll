/* SPDX-License-Identifier: MIT
 * Pure gates and row copy for the unlocked linear readback (M8 fix A).  Kept
 * outside air_metal.c so a host test can exercise the decisions and pitch math
 * without a GPU or a pipe_context.
 */
#ifndef BG_READ_UNLOCKED_H
#define BG_READ_UNLOCKED_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* All arguments are the already-evaluated conditions; no driver types here. */
static inline int
bg_read_unlocked_eligible(int is_2d, int is_depth_stencil, int samples,
                          int tile_mode, int ubwc, int valid,
                          const void *write_batch)
{
   return is_2d && !is_depth_stencil && samples <= 1 && tile_mode == 0 &&
          !ubwc && valid && write_batch == NULL;
}

/* Copy rows from the BO base+offset into the caller's rows.  Returns 0, or -1
 * when the driver pitch is narrower than a row. */
static inline int
bg_copy_linear_rows(void *dst, size_t dst_stride, const uint8_t *base,
                    size_t offset, uint32_t pitch, unsigned x, unsigned y,
                    unsigned width, unsigned height, size_t bytes_per_block)
{
   size_t row = (size_t)width * bytes_per_block;
   if (!dst || !base || pitch < row)
      return -1;
   for (unsigned i = 0; i < height; i++)
      memcpy((uint8_t *)dst + (size_t)i * dst_stride,
             base + offset + (size_t)(y + i) * pitch + (size_t)x * bytes_per_block,
             row);
   return 0;
}
#endif
