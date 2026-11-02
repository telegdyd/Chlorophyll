// SPDX-License-Identifier: MIT
#ifndef BG_REFUSAL_LOG_H
#define BG_REFUSAL_LOG_H
#include <stdint.h>
#include <string.h>

/* Caller serializes the table and callback. No allocation, hashes or truncated
 * keys: different reasons must never disappear behind another reason's count.
 * Summaries are activity-driven, not a timer thread. Eviction flushes its count. */
#define BG_REFUSAL_SLOTS 16
#define BG_REFUSAL_REASON 512
#define BG_REFUSAL_PERIOD_NS UINT64_C(5000000000)
struct bg_refusal_entry {
   unsigned kind;
   char reason[BG_REFUSAL_REASON];
   uint64_t suppressed;
   int used;
};
struct bg_refusal_log {
   struct bg_refusal_entry entries[BG_REFUSAL_SLOTS];
   unsigned next;
   uint64_t last_summary;
   int started;
};
typedef void (*bg_refusal_emit)(void *, unsigned, const char *, uint64_t);

/* emit(..., 0) is the original error; nonzero is the suppressed repeat count.
 * Returns 1 only when the original error was emitted. */
static int
bg_refusal_note(struct bg_refusal_log *log, unsigned kind, const char *reason,
                uint64_t now, bg_refusal_emit emit, void *ctx)
{
   if (!log->started) { log->started = 1; log->last_summary = now; }
   if (now - log->last_summary >= BG_REFUSAL_PERIOD_NS) {
      for (unsigned i = 0; i < BG_REFUSAL_SLOTS; ++i) {
         struct bg_refusal_entry *e = &log->entries[i];
         if (e->suppressed) {
            emit(ctx, e->kind, e->reason, e->suppressed);
            e->suppressed = 0;
         }
      }
      log->last_summary = now;
   }
   /* Refuse to aggregate an overlong key rather than conflate suffixes. */
   if (strlen(reason) >= BG_REFUSAL_REASON) {
      emit(ctx, kind, reason, 0);
      return 1;
   }
   for (unsigned i = 0; i < BG_REFUSAL_SLOTS; ++i) {
      struct bg_refusal_entry *e = &log->entries[i];
      if (e->used && e->kind == kind && !strcmp(e->reason, reason)) {
         if (e->suppressed == UINT64_MAX) {
            emit(ctx, kind, reason, e->suppressed);
            e->suppressed = 0;
         }
         ++e->suppressed;
         return 0;
      }
   }
   struct bg_refusal_entry *e = &log->entries[log->next];
   log->next = (log->next + 1) % BG_REFUSAL_SLOTS;
   if (e->suppressed) emit(ctx, e->kind, e->reason, e->suppressed);
   e->kind = kind;
   strcpy(e->reason, reason);
   e->suppressed = 0;
   e->used = 1;
   emit(ctx, kind, reason, 0);
   return 1;
}
#endif
