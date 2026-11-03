/* SPDX-License-Identifier: MIT
 * Host check for bg_timeline.h. Needs macOS headers and libSystem
 * (mach_absolute_time, dispatch, pthread); it does not touch the device.
 *   timeline_test         off path: no ids, no state change
 *   timeline_test armed   arm via the trigger file, run 130 CBs, check the dump */
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "../src/bg_timeline.h"

static int
armed(void)
{
   setenv("BGMTL_TL", "1", 1);
   FILE *t = fopen(BG_TL_TRIGGER, "w");
   assert(t);
   fclose(t);
   uint32_t ids = 0, max_id = 0;
   for (int i = 0; i < 130; i++) {
      uint32_t cb = bg_tl_create();
      if (cb) { ids++; if (cb > max_id) max_id = cb; }
      if (i == 0) {
         /* 20 us must be dropped; 500 us must be recorded as NO_CB. */
         uint64_t short_ticks = (20ull * 1000ull * bg_tl.tb.denom) / bg_tl.tb.numer;
         uint64_t long_ticks = (500ull * 1000ull * bg_tl.tb.denom) / bg_tl.tb.numer;
         bg_tl_lock_wait(1470, mach_absolute_time() - short_ticks);
         bg_tl_lock_wait(1470, mach_absolute_time() - long_ticks);
      }
      bg_tl_event(BG_TL_COMMIT_ENTER, cb, 1, 0);
      bg_tl_ticket(cb, (uint64_t)i | (1ull << 32), 7, i & 1);
      bg_tl_event(BG_TL_SUBMIT_END, cb, (uint64_t)i + 100, 0);
      bg_tl_completed(cb, 4, BG_TL_Q_COMPLETION);
   }
   assert(ids == BG_TL_MAX_CB && max_id == BG_TL_MAX_CB);
   assert(bg_tl.completed == BG_TL_MAX_CB);
   for (int i = 0; i < 2000 && __atomic_load_n(&bg_tl.state, __ATOMIC_ACQUIRE) != BG_TL_DONE; i++)
      usleep(1000);
   assert(bg_tl.state == BG_TL_DONE);
   unlink(BG_TL_TRIGGER);

   char path[128];
   snprintf(path, sizeof(path), "/private/var/tmp/bgmtl-tl-%d.bin", (int)getpid());
   FILE *f = fopen(path, "rb");
   assert(f);
   struct bg_tl_hdr h;
   assert(fread(&h, sizeof(h), 1, f) == 1);
   assert(h.magic == 0x4c544742u && h.version == 1 && h.hdr_size == sizeof(h));
   assert(h.pid == getpid() && h.dropped == 0 && h.numer && h.denom);
   assert(h.count == 5 * BG_TL_MAX_CB + 1);
   unsigned completed = 0, deferred = 0, lock_waits = 0;
   uint64_t last = 0;
   for (uint32_t i = 0; i < h.count; i++) {
      struct bg_tl_rec r;
      assert(fread(&r, sizeof(r), 1, f) == 1);
      assert(r.t >= h.start_ticks && r.t >= last);
      last = r.t;
      if (r.kind == BG_TL_LOCK_WAIT) {
         lock_waits++;
         assert(r.cb == BG_TL_NO_CB);
         assert(r.b > 0);
         assert((r.a >> 48) == 1470u);
         continue;
      }
      assert(r.cb >= 1 && r.cb <= BG_TL_MAX_CB);
      if (r.kind == BG_TL_COMPLETED_RUN) completed++;
      if (r.kind == BG_TL_TICKET_BEGIN && (r.b & BG_TL_TICKET_DEFERRED)) deferred++;
   }
   assert(completed == BG_TL_MAX_CB && deferred == BG_TL_MAX_CB / 2 && lock_waits == 1);
   fclose(f);
   unlink(path);
   /* One-shot: a finished ring hands out no more ids. */
   assert(bg_tl_create() == 0);
   printf("timeline armed: %u records, %u CBs, ok\n", h.count, completed);
   return 0;
}

int main(int argc, char **argv)
{
   if (argc > 1 && !strcmp(argv[1], "armed"))
      return armed();
   unsetenv("BGMTL_TL");
   assert(bg_tl_on() == 0);
   assert(bg_tl_create() == 0);
   bg_tl_event(BG_TL_CREATE, 0, 0, 0);
   bg_tl_ticket(0, 1, 2, 0);
   assert(bg_tl_tid() != 0);
   assert(bg_tl.state == BG_TL_OFF);
   printf("timeline off: ok\n");
   return 0;
}
