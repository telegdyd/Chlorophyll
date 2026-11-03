/* SPDX-License-Identifier: MIT
 * Host test for bg_defer_queue.h: LIFO drain, destroy-before-release, contended
 * producer returning without taking the context lock, and concurrent pushes. */
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "../src/bg_defer_queue.h"

struct tnode {
   struct bg_defer_node node;   /* first */
   int id;
};

static char events[4096];
static size_t event_n;
static pthread_mutex_t events_mtx = PTHREAD_MUTEX_INITIALIZER;

static void
record(char c, int id)
{
   pthread_mutex_lock(&events_mtx);
   int n = snprintf(events + event_n, sizeof(events) - event_n, "%c%d", c, id);
   if (n > 0) event_n += (size_t)n;
   pthread_mutex_unlock(&events_mtx);
}

static void
destroy(struct bg_defer_node *n)
{
   record('D', ((struct tnode *)n)->id);
}

static void
release(struct bg_defer_node *n)
{
   record('R', ((struct tnode *)n)->id);
}

static struct tnode *
mknode(int id)
{
   struct tnode *t = calloc(1, sizeof(*t));
   assert(t);
   t->id = id;
   t->node.destroy = destroy;
   t->node.release = release;
   return t;
}

static void
test_order(void)
{
   event_n = 0;
   assert(bg_defer_drain() == 0);
   for (int i = 1; i <= 3; i++) bg_defer_push(&mknode(i)->node);
   assert(bg_defer_pushed == 3);
   assert(bg_defer_drain() == 3);
   assert(bg_defer_drained == 3);
   assert(strcmp(events, "D3R3D2R2D1R1") == 0);
   assert(bg_defer_drain() == 0);
}

#define NTHREADS 4
#define PER_THREAD 100

static void *
producer(void *arg)
{
   int base = (int)(intptr_t)arg * PER_THREAD;
   for (int i = 0; i < PER_THREAD; i++) bg_defer_push(&mknode(base + i)->node);
   return NULL;
}

static void
test_concurrent(void)
{
   pthread_t th[NTHREADS];
   event_n = 0;
   unsigned long before_pushed = bg_defer_pushed;
   unsigned long before_drained = bg_defer_drained;
   for (int i = 0; i < NTHREADS; i++) assert(pthread_create(&th[i], NULL, producer, (void *)(intptr_t)i) == 0);
   for (int i = 0; i < NTHREADS; i++) assert(pthread_join(th[i], NULL) == 0);
   assert(bg_defer_pushed == before_pushed + NTHREADS * PER_THREAD);
   unsigned drained = bg_defer_drain();
   assert(drained == NTHREADS * PER_THREAD);
   assert(bg_defer_drained == before_drained + NTHREADS * PER_THREAD);
}

static pthread_mutex_t ctx_mtx = PTHREAD_MUTEX_INITIALIZER;

static void *
hold_lock(void *arg)
{
   pthread_mutex_lock(&ctx_mtx);
   *(int *)arg = 1;
   usleep(100000);
   pthread_mutex_unlock(&ctx_mtx);
   return NULL;
}

static void
test_contended_producer(void)
{
   int held = 0;
   pthread_t th;
   assert(pthread_create(&th, NULL, hold_lock, &held) == 0);
   while (!__atomic_load_n(&held, __ATOMIC_ACQUIRE)) usleep(1000);

   struct timespec a, b;
   clock_gettime(CLOCK_MONOTONIC, &a);
   int lock_rc = pthread_mutex_trylock(&ctx_mtx);
   assert(lock_rc != 0);   /* contended: do not take it */
   bg_defer_push(&mknode(42)->node);
   clock_gettime(CLOCK_MONOTONIC, &b);
   double ms = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
   assert(ms < 100.0);     /* push returns without waiting for the holder */

   assert(pthread_join(th, NULL) == 0);
   assert(bg_defer_drain() == 1);
   assert(strstr(events, "D42R42") != NULL);
}

int main(void)
{
   test_order();
   test_concurrent();
   test_contended_producer();
   puts("PASS: deferred destroy queue LIFO, destroy-before-release, concurrent push, contended producer returns");
   return 0;
}
