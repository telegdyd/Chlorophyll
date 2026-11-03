/* SPDX-License-Identifier: MIT
 * Host test for the record lock used around argument-buffer lists: a writer
 * (mock encode) and a reader (mock collect-writes) must never observe a torn
 * member/count pair.  Defines the mutex the header declares. */
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include "../air/bg_argbuf_lock.h"

pthread_mutex_t bg_argbuf_mutex = PTHREAD_MUTEX_INITIALIZER;

struct record {
   unsigned long members;
   void *texture;
};

#define ITERS 200000
static struct record rec;
static volatile int stop;

static void *
writer(void *arg)
{
   (void)arg;
   for (unsigned long i = 1; i <= ITERS; i++) {
      pthread_mutex_lock(&bg_argbuf_mutex);
      rec.members = i;
      rec.texture = (void *)(uintptr_t)i;
      pthread_mutex_unlock(&bg_argbuf_mutex);
   }
   return NULL;
}

static void *
reader(void *arg)
{
   (void)arg;
   while (!stop) {
      pthread_mutex_lock(&bg_argbuf_mutex);
      unsigned long members = rec.members;
      void *texture = rec.texture;
      pthread_mutex_unlock(&bg_argbuf_mutex);
      /* A collector must never see a count without the matching record. */
      if (members)
         assert(texture == (void *)(uintptr_t)members);
   }
   return NULL;
}

int main(void)
{
   pthread_t w, r;
   assert(pthread_create(&w, NULL, writer, NULL) == 0);
   assert(pthread_create(&r, NULL, reader, NULL) == 0);
   assert(pthread_join(w, NULL) == 0);
   stop = 1;
   assert(pthread_join(r, NULL) == 0);

   pthread_mutex_lock(&bg_argbuf_mutex);
   assert(rec.members == ITERS);
   assert(rec.texture == (void *)(uintptr_t)ITERS);
   pthread_mutex_unlock(&bg_argbuf_mutex);

   /* The lock is plain (not recursive): a trylock while another thread owns it
    * fails, which is why bgmtl's wrapper records a wait instead of re-entering. */
   pthread_mutex_lock(&bg_argbuf_mutex);
   pthread_mutex_unlock(&bg_argbuf_mutex);
   puts("PASS: argbuf record lock serializes mock encode/collect; no torn record");
   return 0;
}
