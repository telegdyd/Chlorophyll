/* SPDX-License-Identifier: MIT
 * Host test for the recursive context-lock bypass used by rwaTextureSampled/
 * rwaTexture: a thread already holding the recursive mutex must not take it
 * again; another thread must still block. */
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static __thread int depth;

static void
lock(void)
{
   if (depth) { depth++; return; }
   pthread_mutex_lock(&mutex);
   depth = 1;
}

static void
unlock(void)
{
   assert(depth > 0);
   if (--depth == 0)
      pthread_mutex_unlock(&mutex);
}

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready_cv = PTHREAD_COND_INITIALIZER, go_cv = PTHREAD_COND_INITIALIZER;
static int ready, go;

static void *
holder(void *arg)
{
   (void)arg;
   lock();
   assert(depth == 1);
   lock();                 /* same thread: depth only */
   assert(depth == 2);
   pthread_mutex_lock(&gate);
   ready = 1;
   pthread_cond_signal(&ready_cv);
   while (!go)
      pthread_cond_wait(&go_cv, &gate);
   pthread_mutex_unlock(&gate);
   unlock();
   assert(depth == 1);
   unlock();
   assert(depth == 0);
   return NULL;
}

int main(void)
{
   pthread_t t;
   assert(pthread_create(&t, NULL, holder, NULL) == 0);
   pthread_mutex_lock(&gate);
   while (!ready)
      pthread_cond_wait(&ready_cv, &gate);
   pthread_mutex_unlock(&gate);
   assert(pthread_mutex_trylock(&mutex) != 0);   /* held by holder */
   pthread_mutex_lock(&gate);
   go = 1;
   pthread_cond_signal(&go_cv);
   pthread_mutex_unlock(&gate);
   assert(pthread_join(t, NULL) == 0);
   assert(pthread_mutex_trylock(&mutex) == 0);   /* released */
   pthread_mutex_unlock(&mutex);
   puts("PASS: recursive depth bypass is per-thread; other threads still block");
   return 0;
}
