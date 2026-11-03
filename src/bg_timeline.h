/* SPDX-License-Identifier: MIT */
/* M8 per-command-buffer timeline ring. One fixed 8192 x 32-byte table, armed
 * by /private/var/tmp/bgmtl-tl-start when BGMTL_TL=1. Records are appended by
 * an atomic fetch-add; no lock, allocation or clock read happens unless the
 * ring is armed. The single dump runs on a background queue after the replay
 * locks are released.
 *
 * Record: { uint64 t (mach_absolute_time); uint32 kind; uint32 cb;
 *           uint64 a; uint64 b; }
 * Header: 'B','G','T','L', version 1, pid, count, dropped, start/end ticks,
 *         mach timebase numer/denom. All little-endian on arm64.
 */
#ifndef BG_TIMELINE_H
#define BG_TIMELINE_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>

#define BG_TL_CAP 8192u
#define BG_TL_MAX_CB 120u
#define BG_TL_TRIGGER "/private/var/tmp/bgmtl-tl-start"
#define BG_TL_TICKET_DEFERRED (1ull << 63)

enum {
   BG_TL_OFF = 0, BG_TL_ARMING, BG_TL_ARMED, BG_TL_STOPPING, BG_TL_DONE
};
enum {
   BG_TL_CREATE = 1, BG_TL_COMMIT_ENTER, BG_TL_REPLAY_BEGIN, BG_TL_TICKET_BEGIN,
   BG_TL_SUBMIT_BEGIN, BG_TL_SUBMIT_END, BG_TL_REPLAY_END, BG_TL_SCHEDULED_RUN,
   BG_TL_FENCE_OBSERVED, BG_TL_COMPLETED_RUN, BG_TL_PRESENT_POST, BG_TL_PRESENT_ENTER,
   BG_TL_LOCK_WAIT, BG_TL_HANDLERS_BEGIN, BG_TL_DEFER_DRAIN
};
/* LOCK_WAIT belongs to no CB: a = file<<62 | line<<48 | thread id, b = ticks waited. */
#define BG_TL_NO_CB 0xffffffffu
#define BG_TL_LOCK_WAIT_MIN_NS 100000ull
enum { BG_TL_Q_REPLAY = 0, BG_TL_Q_COMPLETION = 1, BG_TL_Q_INLINE = 2 };

struct bg_tl_rec {
   uint64_t t;
   uint32_t kind;
   uint32_t cb;
   uint64_t a, b;
};
struct bg_tl_hdr {
   uint32_t magic;
   uint16_t version, hdr_size;
   int32_t pid;
   uint32_t count, dropped, pad;
   uint64_t start_ticks, end_ticks;
   uint32_t numer, denom;
};
static struct {
   struct bg_tl_rec rec[BG_TL_CAP];
   volatile uint32_t idx, dropped, writers, cbs, next_cb, completed;
   volatile uint64_t start, end, stop;
   volatile int state;
   mach_timebase_info_data_t tb;
} bg_tl;

/* Cached env check: one predictable branch per emit site when BGMTL_TL is off. */
static inline int
bg_tl_on(void)
{
   static int on = -1;
   if (on < 0) {
      const char *v = getenv("BGMTL_TL");
      on = v && v[0] == '1' ? 1 : 0;
   }
   return on;
}

static inline uint64_t
bg_tl_tid(void)
{
   static __thread uint64_t tid;
   if (!tid) pthread_threadid_np(NULL, &tid);
   return tid;
}

static void bg_tl_write_file(void *arg);
static void bg_tl_timeout(void *arg);

static inline void
bg_tl_stop(void)
{
   int expected = BG_TL_ARMED;
   if (!__atomic_compare_exchange_n(&bg_tl.state, &expected, BG_TL_STOPPING, 0,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
      return;
   bg_tl.stop = mach_absolute_time();
   dispatch_async_f(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), NULL, bg_tl_write_file);
}

static inline void
bg_tl_try_arm(void)
{
   int expected = BG_TL_OFF;
   if (!__atomic_compare_exchange_n(&bg_tl.state, &expected, BG_TL_ARMING, 0,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
      return;
   if (access(BG_TL_TRIGGER, F_OK) != 0) {
      __atomic_store_n(&bg_tl.state, BG_TL_OFF, __ATOMIC_RELEASE);
      return;
   }
   mach_timebase_info_data_t tb;
   if (mach_timebase_info(&tb) != KERN_SUCCESS || tb.numer == 0 || tb.denom == 0) {
      __atomic_store_n(&bg_tl.state, BG_TL_OFF, __ATOMIC_RELEASE);
      return;
   }
   uint64_t now = mach_absolute_time();
   bg_tl.tb = tb;
   bg_tl.start = now;
   /* 8 s in mach ticks; 8e9 * denom fits comfortably in uint64. */
   bg_tl.end = now + (uint64_t)((8ull * 1000000000ull * tb.denom) / tb.numer);
   bg_tl.idx = bg_tl.dropped = bg_tl.writers = bg_tl.cbs = bg_tl.next_cb = bg_tl.completed = 0;
   bg_tl.stop = 0;
   __atomic_store_n(&bg_tl.state, BG_TL_ARMED, __ATOMIC_RELEASE);
   dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 8ull * 1000000000ull),
                    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), NULL, bg_tl_timeout);
}

static void
bg_tl_timeout(void *arg)
{
   (void)arg;
   bg_tl_stop();
}

static inline void
bg_tl_append_at(uint64_t now, uint32_t kind, uint32_t cb, uint64_t a, uint64_t b)
{
   if (!cb || __atomic_load_n(&bg_tl.state, __ATOMIC_ACQUIRE) != BG_TL_ARMED)
      return;
   if (now >= __atomic_load_n(&bg_tl.end, __ATOMIC_ACQUIRE)) {
      bg_tl_stop();
      return;
   }
   __atomic_add_fetch(&bg_tl.writers, 1, __ATOMIC_ACQ_REL);
   if (__atomic_load_n(&bg_tl.state, __ATOMIC_ACQUIRE) != BG_TL_ARMED) {
      __atomic_sub_fetch(&bg_tl.writers, 1, __ATOMIC_ACQ_REL);
      return;
   }
   uint32_t n = __atomic_fetch_add(&bg_tl.idx, 1, __ATOMIC_RELAXED);
   if (n < BG_TL_CAP) {
      bg_tl.rec[n] = (struct bg_tl_rec){ now, kind, cb, a, b };
   } else {
      __atomic_add_fetch(&bg_tl.dropped, 1, __ATOMIC_RELAXED);
      __atomic_sub_fetch(&bg_tl.writers, 1, __ATOMIC_ACQ_REL);
      bg_tl_stop();
      return;
   }
   __atomic_sub_fetch(&bg_tl.writers, 1, __ATOMIC_ACQ_REL);
}

static inline void
bg_tl_event(uint32_t kind, uint32_t cb, uint64_t a, uint64_t b)
{
   if (!cb) return;   /* timeline was off or not armed when this CB was created */
   if (__atomic_load_n(&bg_tl.state, __ATOMIC_ACQUIRE) != BG_TL_ARMED) return;
   bg_tl_append_at(mach_absolute_time(), kind, cb, a, b);
}

/* Assign a CB id and record CREATE. Returns 0 when the timeline is off, not
 * armed yet, or already finished, so later sites do no work for this CB. */
static inline uint32_t
bg_tl_create(void)
{
   if (!bg_tl_on()) return 0;
   bg_tl_try_arm();
   if (__atomic_load_n(&bg_tl.state, __ATOMIC_ACQUIRE) != BG_TL_ARMED) return 0;
   uint64_t now = mach_absolute_time();
   if (now >= __atomic_load_n(&bg_tl.end, __ATOMIC_ACQUIRE)) {
      bg_tl_stop();
      return 0;
   }
   /* Past the CB budget, hand out no new ids but keep recording the CBs already
    * in flight; the ring stops when they have all completed (or at 8 s). */
   uint32_t n = __atomic_add_fetch(&bg_tl.cbs, 1, __ATOMIC_RELAXED);
   if (n > BG_TL_MAX_CB) {
      __atomic_sub_fetch(&bg_tl.cbs, 1, __ATOMIC_RELAXED);
      return 0;
   }
   uint32_t cb = __atomic_add_fetch(&bg_tl.next_cb, 1, __ATOMIC_RELAXED);
   bg_tl_append_at(now, BG_TL_CREATE, cb, 0, 0);
   return cb;
}

/* The CB's last event; stops the ring once every budgeted CB has completed. */
static inline void
bg_tl_completed(uint32_t cb, uint64_t status, uint64_t queue)
{
   if (!cb || __atomic_load_n(&bg_tl.state, __ATOMIC_ACQUIRE) != BG_TL_ARMED) return;
   bg_tl_append_at(mach_absolute_time(), BG_TL_COMPLETED_RUN, cb, status, queue);
   if (__atomic_add_fetch(&bg_tl.completed, 1, __ATOMIC_ACQ_REL) >= BG_TL_MAX_CB)
      bg_tl_stop();
}

static inline void
bg_tl_ticket(uint32_t cb, uint64_t generation, uint64_t epoch, int deferred)
{
   bg_tl_event(BG_TL_TICKET_BEGIN, cb, generation,
               deferred ? (epoch | BG_TL_TICKET_DEFERRED) : epoch);
}

/* A bg_lock that did not get the lock at once and waited at least 100 us. t0: before the blocking lock. */
static inline void
bg_tl_lock_wait(uint64_t site, uint64_t t0)
{
   uint64_t now = mach_absolute_time();
   if ((now - t0) * bg_tl.tb.numer / bg_tl.tb.denom < BG_TL_LOCK_WAIT_MIN_NS) return;
   bg_tl_append_at(now, BG_TL_LOCK_WAIT, BG_TL_NO_CB,
                   (site << 48) | (bg_tl_tid() & 0xffffffffffffull), now - t0);
}

static void
bg_tl_write_file(void *arg)
{
   (void)arg;
   while (__atomic_load_n(&bg_tl.writers, __ATOMIC_ACQUIRE)) usleep(1000);
   uint32_t n = __atomic_load_n(&bg_tl.idx, __ATOMIC_ACQUIRE);
   if (n > BG_TL_CAP) n = BG_TL_CAP;
   struct bg_tl_rec *copy = n ? malloc((size_t)n * sizeof(*copy)) : NULL;
   if (n && !copy) {
      __atomic_store_n(&bg_tl.state, BG_TL_DONE, __ATOMIC_RELEASE);
      return;
   }
   if (n) memcpy(copy, bg_tl.rec, (size_t)n * sizeof(*copy));
   struct bg_tl_hdr h = {
      .magic = 0x4c544742u,   /* bytes 'B','G','T','L' on little-endian arm64 */
      .version = 1,
      .hdr_size = (uint16_t)sizeof(h),
      .pid = (int32_t)getpid(),
      .count = n,
      .dropped = __atomic_load_n(&bg_tl.dropped, __ATOMIC_ACQUIRE),
      .pad = 0,
      .start_ticks = bg_tl.start,
      .end_ticks = bg_tl.stop ? bg_tl.stop : bg_tl.end,
      .numer = bg_tl.tb.numer,
      .denom = bg_tl.tb.denom,
   };
   char path[128];
   snprintf(path, sizeof(path), "/private/var/tmp/bgmtl-tl-%d.bin", (int)getpid());
   FILE *f = fopen(path, "wb");
   if (f) {
      fwrite(&h, sizeof(h), 1, f);
      if (n) fwrite(copy, sizeof(*copy), n, f);
      fclose(f);
   }
   free(copy);
   __atomic_store_n(&bg_tl.state, BG_TL_DONE, __ATOMIC_RELEASE);
}
#endif
