/* SPDX-License-Identifier: MIT
 * Host concurrency test for the texture-pool ownership pattern used by the
 * unlocked create path: producers put nodes, consumers take them, and the mutex
 * is the only shared state.  The real pool's pipe-side expiry was moved to the
 * bg_lock-held put path; this checks the lock discipline with ASan/UBSan. */
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

struct node { int id; struct node *next; };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct node *head;
static atomic_int produced, consumed;
#define PRODUCERS 4
#define CONSUMERS 4
#define PER_PRODUCER 1000
#define TOTAL (PRODUCERS * PER_PRODUCER)

static void *
producer(void *arg)
{
   (void)arg;
   for (int i = 0; i < PER_PRODUCER; i++) {
      struct node *n = malloc(sizeof(*n));
      assert(n);
      n->id = i;
      pthread_mutex_lock(&lock);
      n->next = head;
      head = n;
      pthread_mutex_unlock(&lock);
      atomic_fetch_add(&produced, 1);
   }
   return NULL;
}

static void *
consumer(void *arg)
{
   (void)arg;
   for (;;) {
      struct node *n;
      pthread_mutex_lock(&lock);
      n = head;
      if (n) head = n->next;
      pthread_mutex_unlock(&lock);
      if (!n) {
         if (atomic_load(&produced) == TOTAL && atomic_load(&consumed) == TOTAL)
            break;
         continue;
      }
      free(n);
      atomic_fetch_add(&consumed, 1);
   }
   return NULL;
}

int main(void)
{
   pthread_t p[PRODUCERS], c[CONSUMERS];
   for (int i = 0; i < CONSUMERS; i++) assert(pthread_create(&c[i], NULL, consumer, NULL) == 0);
   for (int i = 0; i < PRODUCERS; i++) assert(pthread_create(&p[i], NULL, producer, NULL) == 0);
   for (int i = 0; i < PRODUCERS; i++) assert(pthread_join(p[i], NULL) == 0);
   for (int i = 0; i < CONSUMERS; i++) assert(pthread_join(c[i], NULL) == 0);
   assert(head == NULL);
   assert(atomic_load(&produced) == TOTAL);
   assert(atomic_load(&consumed) == TOTAL);
   puts("PASS: concurrent pool put/take ownership; every node taken once");
   return 0;
}
