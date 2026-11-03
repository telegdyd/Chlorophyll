/* SPDX-License-Identifier: MIT
 * MPSC list for work that cannot run on the thread that last-released an object
 * (here: pipe_context destroy while another thread holds bg_lock).  Push is
 * lock-free; drain is single-threaded and must be called while the same lock
 * that the producers contend on is held.  No allocation or clock here: the
 * caller owns node lifetime and the callback work.
 */
#ifndef BG_DEFER_QUEUE_H
#define BG_DEFER_QUEUE_H
#include <stdint.h>
#include <stdlib.h>

struct bg_defer_node {
   struct bg_defer_node *next;
   void (*destroy)(struct bg_defer_node *);
   void (*release)(struct bg_defer_node *);
};

static struct bg_defer_node *bg_defer_head;
static volatile int bg_defer_draining;
static volatile unsigned long bg_defer_pushed, bg_defer_drained;

/* Push one node.  The producer fills destroy/release before calling. */
static inline void
bg_defer_push(struct bg_defer_node *n)
{
   struct bg_defer_node *head = __atomic_load_n(&bg_defer_head, __ATOMIC_ACQUIRE);
   for (;;) {
      n->next = head;
      if (__atomic_compare_exchange_n(&bg_defer_head, &head, n, 0,
                                      __ATOMIC_RELEASE, __ATOMIC_ACQUIRE))
         break;
   }
   __atomic_add_fetch(&bg_defer_pushed, 1, __ATOMIC_RELAXED);
}

/* Drain everything present when called.  destroy then release, per node, in
 * LIFO push order (a stack; order is not otherwise meaningful).  Returns the
 * number of nodes drained.  Re-entry returns 0; new pushes during the drain
 * wait for the next call. */
static inline unsigned
bg_defer_drain(void)
{
   if (__atomic_exchange_n(&bg_defer_draining, 1, __ATOMIC_ACQ_REL))
      return 0;
   struct bg_defer_node *list = __atomic_exchange_n(&bg_defer_head, NULL, __ATOMIC_ACQUIRE);
   unsigned n = 0;
   while (list) {
      struct bg_defer_node *next = list->next;
      list->destroy(list);
      list->release(list);
      free(list);
      n++;
      list = next;
   }
   __atomic_add_fetch(&bg_defer_drained, n, __ATOMIC_RELAXED);
   __atomic_store_n(&bg_defer_draining, 0, __ATOMIC_RELEASE);
   return n;
}
#endif
