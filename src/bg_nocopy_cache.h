// SPDX-License-Identifier: MIT
// Exact comparison cache for packed no-copy textures. Caller holds bg_lock.
// Caller memory remains mutable: compare every refresh epoch, never by hash.
// Experimental until a matched CPU gain is established: BGMTL_NOCOPY_CACHE=1.
// At most 2 MiB per texture / 8 MiB per process; allocation failure uses uploads.
struct bg_nc_cache { void *bytes; size_t size; int valid; };
static size_t bg_nc_cache_bytes;
static int bg_nc_cache_on(void)
{
   static int on;
   if (!on) on = getenv("BGMTL_NOCOPY_CACHE") && getenv("BGMTL_NOCOPY_CACHE")[0] == '1' ? 1 : -1;
   return on == 1;
}
static int bg_nc_cache_match(const struct bg_nc_cache *c, const void *bytes)
{ return c->valid && !memcmp(c->bytes, bytes, c->size); }
static void bg_nc_cache_store(struct bg_nc_cache *c, const void *bytes, size_t size)
{
   if (!bg_nc_cache_on() || !size || size > 2*1024*1024) return;
   if (!c->bytes) {
      if (size > 8*1024*1024 - bg_nc_cache_bytes) return;
      c->bytes = malloc(size);
      if (!c->bytes) return;
      c->size = size;
      bg_nc_cache_bytes += size;
   }
   if (size != c->size) { c->valid = 0; return; }
   memcpy(c->bytes, bytes, size);
   c->valid = 1;
}
static void bg_nc_cache_destroy(struct bg_nc_cache *c)
{
   if (c->bytes) { bg_nc_cache_bytes -= c->size; free(c->bytes); }
   memset(c, 0, sizeof(*c));
}
