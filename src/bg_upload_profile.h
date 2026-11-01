// SPDX-License-Identifier: MIT
// Opt-in M1 inventory. All calls hold bg_lock. Fixed storage; no pixel dumps.
// Arm with BGMTL_UPLOAD_PROFILE=1, then create bgmtl-upload-start after settling.
// One 120-command-buffer capture per process; command buffers are NOT display frames.
#define BG_UPLOAD_RECORDS 256
#define BG_UPLOAD_FRAMES 120
static struct {
   int enabled, active, finished;
   unsigned frames, count;
   uint64_t next_id, overflow, hash_bytes, deadline;
   struct { uint64_t bytes, writes, skipped, failed; } frame[BG_UPLOAD_FRAMES];
   struct {
      uint64_t id, bytes, writes, first, changed, same_hash, unknown, skipped, failed;
      uint64_t hash, last_commit;
      uintptr_t source, resource;
      size_t offset, pitch, length;
      unsigned width, height, format, mips, kind, commits;
      int have_hash;
   } record[BG_UPLOAD_RECORDS];
} bg_upload;

static int bg_upload_enabled(void)
{
   if (!bg_upload.enabled)
      bg_upload.enabled = getenv("BGMTL_UPLOAD_PROFILE") && getenv("BGMTL_UPLOAD_PROFILE")[0] == '1' ? 1 : -1;
   return bg_upload.enabled == 1 && !bg_upload.finished;
}

static void bg_upload_begin(void)
{
   if (!bg_upload_enabled() || bg_upload.active) return;
   if (access("/private/var/tmp/bgmtl-upload-start", F_OK)) return;
   bg_upload.active = 1;
   bg_upload.deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + 8000000000ull;
   BG_LOG("upload inventory: started (120 command buffers / 8 seconds)\n");
}

static void bg_upload_end(void)
{
   if (!bg_upload.active) return;
   if (++bg_upload.frames < BG_UPLOAD_FRAMES && clock_gettime_nsec_np(CLOCK_MONOTONIC) < bg_upload.deadline) return;
   bg_upload.active = 0;
   bg_upload.finished = 1;
   char path[128];
   snprintf(path, sizeof(path), "/private/var/tmp/bgmtl-uploads-%d.csv", getpid());
   FILE *f = fopen(path, "w");
   if (!f) { BG_LOG("upload inventory: cannot write %s\n", path); return; }
   fprintf(f, "# command_buffers=%u,overflow_observations=%llu,hashed_bytes=%llu,hash_budget=268435456\n",
           bg_upload.frames, (unsigned long long)bg_upload.overflow, (unsigned long long)bg_upload.hash_bytes);
   fprintf(f, "commit,bytes,writes,epoch_skips,failures\n");
   for (unsigned i = 0; i < bg_upload.frames; i++)
      fprintf(f, "%u,%llu,%llu,%llu,%llu\n", i + 1,
              (unsigned long long)bg_upload.frame[i].bytes, (unsigned long long)bg_upload.frame[i].writes,
              (unsigned long long)bg_upload.frame[i].skipped, (unsigned long long)bg_upload.frame[i].failed);
   fprintf(f, "id,kind,source,resource,offset,pitch,length,width,height,format,mips,bytes,writes,first_upload,changed,same_hash,unknown,epoch_skips,failures,commits\n");
   for (unsigned i = 0; i < bg_upload.count; i++) {
      const typeof(bg_upload.record[0]) *r = &bg_upload.record[i];
      fprintf(f, "%llu,%s,%p,%p,%zu,%zu,%zu,%u,%u,%u,%u,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%u\n",
              (unsigned long long)r->id, r->kind == 0 ? "linear-buffer" : r->kind == 1 ? "no-copy-packed" : "copied-surface",
              (void *)r->source, (void *)r->resource, r->offset, r->pitch, r->length, r->width, r->height, r->format, r->mips,
              (unsigned long long)r->bytes, (unsigned long long)r->writes, (unsigned long long)r->first,
              (unsigned long long)r->changed, (unsigned long long)r->same_hash, (unsigned long long)r->unknown,
              (unsigned long long)r->skipped, (unsigned long long)r->failed, r->commits);
   }
   fclose(f);
   BG_LOG("upload inventory: %u command buffers, %u resources -> %s (diagnostic hash overhead; not a timing run)\n",
          bg_upload.frames, bg_upload.count, path);
}

// status: 0 uploaded, 1 epoch reuse, -1 failed. Hash equality is evidence only,
// never a reason to skip an upload. Padding is excluded; compressed block rows
// and packed mip offsets come from the same format helpers as the write path.
static void bg_upload_note(uint64_t *identity, uint64_t lifetime_writes, unsigned kind,
                           struct rwa_texture *tex, const struct rwa_texture_shape *shape,
                           const void *source, const void *bytes, size_t length,
                           size_t offset, size_t pitch, int status)
{
   if (!bg_upload_enabled() || !bg_upload.active) return;
   if (!*identity) *identity = ++bg_upload.next_id;
   unsigned i;
   for (i = 0; i < bg_upload.count; i++) if (bg_upload.record[i].id == *identity) break;
   typeof(bg_upload.frame[0]) *frame = &bg_upload.frame[bg_upload.frames];
   if (status > 0) frame->skipped++;
   else if (status < 0) frame->failed++;
   uint64_t total = 0;
   unsigned levels = kind == 1 ? shape->mip_levels : 1;
   for (unsigned l = 0; l < levels; l++) {
      size_t row; unsigned rows;
      if (rwa_texture_upload_layout(tex, l, &row, &rows)) return;
      total += (uint64_t)row * rows;
   }
   if (!status) { frame->bytes += total; frame->writes++; }
   if (i == BG_UPLOAD_RECORDS) { bg_upload.overflow++; return; }
   typeof(bg_upload.record[0]) *r = &bg_upload.record[i];
   if (i == bg_upload.count) {
      bg_upload.count++;
      r->id = *identity; r->kind = kind; r->source = (uintptr_t)source; r->resource = (uintptr_t)tex;
      r->offset = offset; r->pitch = pitch; r->length = length;
      r->width = shape->width; r->height = shape->height; r->format = shape->pixel_format; r->mips = shape->mip_levels;
   }
   if (r->last_commit != bg_upload.frames + 1) { r->last_commit = bg_upload.frames + 1; r->commits++; }
   if (status > 0) { r->skipped++; return; }
   if (status < 0) { r->failed++; return; }
   r->bytes += total; r->writes++;
   uint64_t hash = 14695981039346656037ull;
   int valid = bytes && total <= 268435456ull - bg_upload.hash_bytes;
   size_t pos = 0;
   for (unsigned l = 0; valid && l < levels; l++) {
      size_t row; unsigned rows;
      if (rwa_texture_upload_layout(tex, l, &row, &rows)) { valid = 0; break; }
      size_t stride = kind == 1 || !pitch ? row : pitch;
      if (!rows || stride < row || pos > length || row > length - pos ||
          (rows - 1) > (length - pos - row) / stride) { valid = 0; break; }
      for (unsigned y = 0; y < rows; y++) {
         const uint8_t *p = (const uint8_t *)bytes + pos + y * stride;
         for (size_t x = 0; x < row; x++) { hash ^= p[x]; hash *= 1099511628211ull; }
      }
      pos += row * rows; // only packed sources have more than one level
   }
   if (valid) bg_upload.hash_bytes += total;
   if (lifetime_writes == 1) r->first++;
   else if (!valid || !r->have_hash) r->unknown++;
   else if (hash == r->hash) r->same_hash++;
   else r->changed++;
   r->have_hash = valid;
   r->hash = hash;
}
