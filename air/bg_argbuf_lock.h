/* SPDX-License-Identifier: MIT
 * Record lock for freedreno argument-buffer encodings (M8 fix B).  The mutex is
 * process-wide and defined in air_metal.c; bgmtl.m uses it around the shader
 * write-destination walk and records its waits in the timeline with file tag 3.
 * Lock order is always bg_ctx_mutex -> bg_argbuf_mutex.  Nothing under this
 * mutex may take bg_ctx_mutex, use pipe_context, or wait on the GPU.
 */
#ifndef BG_ARGBUF_LOCK_H
#define BG_ARGBUF_LOCK_H
#include <pthread.h>

extern pthread_mutex_t bg_argbuf_mutex;
#endif
