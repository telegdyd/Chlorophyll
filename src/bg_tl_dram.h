/* SPDX-License-Identifier: MIT
 * M9 DRAM byte-attribution packing, shared by bgmtl.m and the host test.
 *
 * a for PASS_ATTACH/PASS_SAMPLE:
 *   pass_id:12 | role:2 | class:2 | load:2 | store:2 | samples:4 |
 *   bpp:8 | height:13 | width:13
 * role 0 colour, 1 depth/stencil, 2 sampled.  class 1 surface, 2 private,
 * 3 other.  b is bytes for one full base-level surface.
 *
 * a for BLIT: kind:4 | src_class:2 | dst_class:2; b is bytes.
 * PASS: a = pass id; b = draws:16 | attachments:8 (gmem bits reserved zero).
 */
#ifndef BG_TL_DRAM_H
#define BG_TL_DRAM_H
#include <stdint.h>

static inline uint64_t
bg_tl_dram_pack_surface(unsigned pass, unsigned role, unsigned cls, unsigned load,
                        unsigned store, unsigned samples, unsigned bpp,
                        unsigned width, unsigned height)
{
   if (width > 0x1fffu) width = 0x1fffu;
   if (height > 0x1fffu) height = 0x1fffu;
   return ((uint64_t)(pass & 0xfffu)) |
          ((uint64_t)(role & 3) << 12) |
          ((uint64_t)(cls & 3) << 14) |
          ((uint64_t)(load & 3) << 16) |
          ((uint64_t)(store & 3) << 18) |
          ((uint64_t)(samples & 15) << 20) |
          ((uint64_t)(bpp & 0xff) << 24) |
          ((uint64_t)height << 32) |
          ((uint64_t)width << 45);
}

static inline void
bg_tl_dram_unpack_surface(uint64_t a, unsigned *pass, unsigned *role, unsigned *cls,
                          unsigned *load, unsigned *store, unsigned *samples,
                          unsigned *bpp, unsigned *width, unsigned *height)
{
   if (pass) *pass = a & 0xfff;
   if (role) *role = (a >> 12) & 3;
   if (cls) *cls = (a >> 14) & 3;
   if (load) *load = (a >> 16) & 3;
   if (store) *store = (a >> 18) & 3;
   if (samples) *samples = (a >> 20) & 15;
   if (bpp) *bpp = (a >> 24) & 0xff;
   if (height) *height = (a >> 32) & 0x1fff;
   if (width) *width = (a >> 45) & 0x1fff;
}

static inline uint64_t
bg_tl_dram_pack_blit(unsigned kind, unsigned src_class, unsigned dst_class)
{
   return (kind & 15) | ((uint64_t)(src_class & 3) << 4) |
          ((uint64_t)(dst_class & 3) << 6);
}
#endif
