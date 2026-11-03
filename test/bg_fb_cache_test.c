/* SPDX-License-Identifier: MIT
 * Host test for the framebuffer-bind skip tracker used by air_metal.c:
 * same surfaces skip, a changed surface binds, and gs_invalidate (blitter /
 * release) forces the next bind. */
#include <assert.h>
#include <stdio.h>
#include <string.h>

struct fb {
   unsigned width, height, nr_cbufs;
   const void *cbuf[4];
   const void *zsbuf;
};
static struct fb last;
static int valid;

static int
fb_equal(const struct fb *a, const struct fb *b)
{
   if (a->width != b->width || a->height != b->height || a->nr_cbufs != b->nr_cbufs ||
       a->zsbuf != b->zsbuf)
      return 0;
   for (unsigned i = 0; i < a->nr_cbufs; i++)
      if (a->cbuf[i] != b->cbuf[i])
         return 0;
   return 1;
}

static int binds;
static void
bind(const struct fb *fb)
{
   if (valid && fb_equal(&last, fb))
      return;
   last = *fb;
   valid = 1;
   binds++;
}

static void
invalidate(void)
{
   valid = 0;
   memset(&last, 0, sizeof(last));
}

int main(void)
{
   int a, b, c;
   struct fb f = { 100, 200, 2, { &a, &b }, &c };
   bind(&f);
   bind(&f);                    /* skip */
   assert(binds == 1);
   f.cbuf[1] = &c;              /* changed attachment */
   bind(&f);
   assert(binds == 2);
   invalidate();                /* blitter / fb_release_texture */
   bind(&f);
   assert(binds == 3);
   puts("PASS: fb tracker skips equal, binds changed, resets on invalidate");
   return 0;
}
