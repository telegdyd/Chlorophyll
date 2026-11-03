/* SPDX-License-Identifier: MIT */
#ifndef BG_UBWC_H
#define BG_UBWC_H
#include <stdbool.h>
#include <stdint.h>

/* Metal enums, deliberately independent of Gallium for the host test. */
static inline bool
bg_ubwc_eligible(unsigned format, unsigned type, unsigned depth,
                 unsigned layers, unsigned levels, unsigned samples,
                 unsigned usage, bool candidate, bool imported)
{
   return candidate && !imported && (format == 70 || format == 80) &&
          type == 2 && depth == 1 && layers == 1 && levels == 1 &&
          samples <= 1 && (usage & 4) && !(usage & 2);
}
#endif
