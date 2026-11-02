// SPDX-License-Identifier: MIT
// clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined refusal_log_test.c -o /tmp/refusal-log-test
#include <assert.h>
#include <stdio.h>
#include "../src/bg_refusal_log.h"
struct output { unsigned originals, summaries, kind; uint64_t repeats; char reason[1024]; };
static void emit(void *ctx, unsigned kind, const char *reason, uint64_t n)
{
   struct output *o = ctx;
   if (n) { ++o->summaries; o->repeats += n; }
   else ++o->originals;
   o->kind = kind;
   assert(strlen(reason) < sizeof(o->reason));
   strcpy(o->reason, reason);
}
int main(void)
{
   struct bg_refusal_log log = {0};
   struct output o = {0};
   const char *why = "pixel format 500 is outside the supported table";
   assert(bg_refusal_note(&log, 0, why, 0, emit, &o));
   for (unsigned i = 0; i < 100000; ++i)
      assert(!bg_refusal_note(&log, 0, why, 1, emit, &o));
   assert(o.originals == 1 && o.summaries == 0);
   assert(!bg_refusal_note(&log, 0, why, BG_REFUSAL_PERIOD_NS, emit, &o));
   assert(o.summaries == 1 && o.repeats == 100000 && !strcmp(o.reason, why));
   /* Same text from a different refusal path is a distinct failure. */
   assert(bg_refusal_note(&log, 1, why, BG_REFUSAL_PERIOD_NS, emit, &o));
   assert(o.originals == 2 && o.kind == 1);
   assert(bg_refusal_note(&log, 0, "new failure", BG_REFUSAL_PERIOD_NS, emit, &o));
   /* Bounded replacement must flush the one outstanding repeat. */
   for (unsigned i = 0; i < BG_REFUSAL_SLOTS; ++i) {
      char key[32]; snprintf(key, sizeof(key), "failure %u", i);
      assert(bg_refusal_note(&log, 0, key, BG_REFUSAL_PERIOD_NS, emit, &o));
   }
   assert(o.repeats == 100001 && o.summaries == 2);
   assert(bg_refusal_note(&log, 0, why, BG_REFUSAL_PERIOD_NS, emit, &o));
   /* Never collapse keys with equal prefixes beyond the storage bound. */
   char big[BG_REFUSAL_REASON + 2]; memset(big, 'a', sizeof(big)); big[sizeof(big)-1] = 0;
   assert(bg_refusal_note(&log, 0, big, BG_REFUSAL_PERIOD_NS, emit, &o));
   big[sizeof(big)-2] = 'b';
   assert(bg_refusal_note(&log, 0, big, BG_REFUSAL_PERIOD_NS, emit, &o));
   assert(o.reason[sizeof(big)-2] == 'b');
   /* A live key keeps receiving periodic summaries; counts never wrap. */
   memset(&log, 0, sizeof(log)); memset(&o, 0, sizeof(o));
   assert(bg_refusal_note(&log, 0, why, 0, emit, &o));
   log.entries[0].suppressed = UINT64_MAX;
   assert(!bg_refusal_note(&log, 0, why, 1, emit, &o));
   assert(o.summaries == 1 && o.repeats == UINT64_MAX && log.entries[0].suppressed == 1);
   memset(&o, 0, sizeof(o));
   assert(!bg_refusal_note(&log, 0, why, BG_REFUSAL_PERIOD_NS, emit, &o));
   assert(o.repeats == 1 && log.entries[0].suppressed == 1);
   assert(!bg_refusal_note(&log, 0, why, 2*BG_REFUSAL_PERIOD_NS, emit, &o));
   assert(o.summaries == 2 && o.repeats == 2);
   puts("refusal log PASS: 100000 repeats, distinct paths/reasons, periodic summaries, eviction, long keys, saturation");
   return 0;
}
