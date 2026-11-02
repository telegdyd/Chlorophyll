/* SPDX-License-Identifier: MIT */
#ifndef BG_TICKET_RETIRE_H
#define BG_TICKET_RETIRE_H
#include <stdint.h>

/* SEAL proves submission, not completion. A refused SEAL (or a missing seqno)
 * requires a successful drain before ABORT can relinquish write ownership.
 * Unacknowledged entries remain with the caller, including after wait failure.
 * The callbacks run under the caller's context lock. */
static int
bg_ticket_retire(uint64_t *generation, uint64_t *epoch, unsigned *count,
                 uint32_t seqno, void *context,
                 int (*end)(void *, uint64_t, uint64_t, int, uint32_t),
                 int (*wait)(void *))
{
   unsigned pending = 0;
   int failed = 0;
   for (unsigned i = 0; i < *count; i++) {
      if (!seqno || end(context, generation[i], epoch[i], 0, seqno)) {
         generation[pending] = generation[i]; epoch[pending++] = epoch[i];
         failed |= seqno != 0;
      }
   }
   *count = pending;
   if (!pending) return 0;
   if (wait(context)) return -1; // retain protection: quiescence is unknown
   pending = 0;
   for (unsigned i = 0; i < *count; i++) {
      if (end(context, generation[i], epoch[i], 1, 0)) {
         generation[pending] = generation[i]; epoch[pending++] = epoch[i];
         failed = 1;
      }
   }
   *count = pending;
   return failed ? -1 : 0;
}
#endif
