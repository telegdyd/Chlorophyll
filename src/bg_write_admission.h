/* SPDX-License-Identifier: MIT */
/* M7 encode-time write ownership. The registry retains a token, not the CB: CB destruction
 * removes its entries under bg_adm_mutex. An unresolved terminal entry is quarantined
 * (surface remains set, owner NULL), never a dangling object pointer.
 *
 * Locking (M8, M10 C). The table and the suspended counters are guarded by bg_adm_mutex,
 * held across check + BEGIN + insert. Encode-time admission takes only bg_adm_mutex
 * (M10 C, see bg_adm_lock); replay-time admission runs under the replay's bg_lock.
 * Release and quarantine take only bg_adm_mutex: completion used to wait on
 * bg_lock for the whole replay of the next command buffer (fence->completed p50
 * 9.9 ms in the M8 captures) just to walk this table. Nothing under
 * bg_adm_mutex takes bg_lock.
 *
 * Display-suspended policy. The kernel clears ticket bit 3 while the presenter is
 * unavailable (display asleep, queue fallback/power-off/terminal), and BEGIN then
 * answers -EAGAIN instead of -ENOTSUP. A suspended presenter cannot scan out, so an
 * encode-time -EAGAIN destination is registered (generation 0) and put on a per-CB
 * deferred list instead of failing the CB. Replay preflight retries BEGIN once: a
 * display that woke gets a real generation and the usual SEAL/ABORT; a still-suspended
 * destination is admitted unticketed and relies on the swap-time gpuSeqno capture,
 * whose submit precedes scheduled/swap. A destination first discovered at replay
 * follows the same unticketed rule. Ownership (uncommitted, replay-time, unknown or
 * quarantined owner), the 32-destination (ticketed, deferred or unticketed) and
 * 1024-entry registry capacity, a stale epoch and
 * tickets-off (-ENOTSUP) or any other BEGIN result still fail the whole CB before any
 * recorded work; only the bit-3 display-unavailable case is deferred. */
#ifdef BG_TL_SITE
#undef bg_lock
#define bg_lock() bg_lock_at(BG_TL_SITE(1, __LINE__))
#endif
#ifndef BG_LOG
#define BG_LOG(...) do { } while (0)
#endif
#define BG_MAX_WRITE_DESTINATIONS 32
#define BG_MAX_PENDING_WRITERS 1024
static struct { unsigned surface; BGWriteOwner *owner; uint64_t generation; }
   bg_pending_writers[BG_MAX_PENDING_WRITERS];
static pthread_mutex_t bg_adm_mutex = PTHREAD_MUTEX_INITIALIZER;
/* M10 C: admission no longer takes bg_lock. BEGIN is two IOConnect calls on the device
 * port (darwin_ticket_begin) and the BO handle is read under fd_screen_lock
 * (rwa_texture_ticket_begin); the table, the counters and every committed flag it reads
 * are under bg_adm_mutex. With bg_lock first, encode-time admission waited behind the
 * whole replay of the previous command buffer (21 waits, 127 ms per 8 s capture). A
 * replay-time admission still runs inside the replay's bg_lock; the order stays
 * bg_lock -> bg_adm_mutex and nothing under bg_adm_mutex takes bg_lock. */
static void bg_adm_lock(void) { pthread_mutex_lock(&bg_adm_mutex); }
static void bg_adm_unlock(void) { pthread_mutex_unlock(&bg_adm_mutex); }
/* Process counters for suspended admission; first event and every 100th are logged,
 * so a long display sleep cannot flood the console. Called under bg_adm_mutex. */
static unsigned bg_suspended_events, bg_suspended_deferred, bg_suspended_reticketed,
                bg_suspended_unticketed;
static void
bg_suspended_event(int force)
{
   unsigned n = ++bg_suspended_events;
   if (force || n == 1 || n % 100 == 0)   // a rare replay reticket is always visible
      BG_LOG("render tickets: display suspended: %u deferred, %u ticketed at replay, %u unticketed\n",
             bg_suspended_deferred, bg_suspended_reticketed, bg_suspended_unticketed);
}

- (BOOL)bgAdmissionReject:(NSString *)reason
{
   _admissionFailed = YES;
   if (!_error) [self bgFailWith:reason code:3];
   return NO;
}
- (void)bgReleaseAdmissionOwners
{
   if (!_writeOwner) return;
   pthread_mutex_lock(&bg_adm_mutex);
   for (unsigned n=0;n<BG_MAX_PENDING_WRITERS;n++) {
      if (bg_pending_writers[n].owner != _writeOwner) continue;
      // Deferred/unticketed entries have no generation and are released here;
      // only a live _tgen can retain an entry across retirement.
      BOOL pending=NO;
      for (unsigned i=0;i<_tcount;i++)
         pending |= bg_pending_writers[n].generation && _tgen[i] == bg_pending_writers[n].generation;
      if (!pending) {
         [bg_pending_writers[n].owner release];
         memset(&bg_pending_writers[n],0,sizeof(bg_pending_writers[n]));
      }
   }
   pthread_mutex_unlock(&bg_adm_mutex);
}
- (void)bgQuarantineAdmissionOwners
{
   if (!_writeOwner) return;
   pthread_mutex_lock(&bg_adm_mutex);
   for (unsigned n=0;n<BG_MAX_PENDING_WRITERS;n++)
      if (bg_pending_writers[n].owner == _writeOwner) {
         [bg_pending_writers[n].owner release]; bg_pending_writers[n].owner=nil;
      }
   pthread_mutex_unlock(&bg_adm_mutex);
}
- (BOOL)bgAdmitRaw:(struct rwa_texture *)texture
{
   unsigned surface=rwa_texture_surface_id(texture);
   if (!surface) return YES;
   bg_adm_lock();
   if (_admissionFailed) { bg_adm_unlock(); return NO; }
   BGWriteOwner *prior=nil;
   unsigned vacant=BG_MAX_PENDING_WRITERS;
   for (unsigned n=0;n<BG_MAX_PENDING_WRITERS;n++) {
      if (!bg_pending_writers[n].surface) vacant=n;
      if (bg_pending_writers[n].surface != surface) continue;
      if (bg_pending_writers[n].owner == _writeOwner) {
         // Deferred at encode: replay preflight retries BEGIN once, because the
         // display may have woken. Remove the entry whichever way it resolves, so
         // a still-suspended destination is never retried twice.
         unsigned d=0;
         while (d<_dcount && _dsurf[d]!=surface) d++;
         if (!_committed || bg_pending_writers[n].generation || d==_dcount) { bg_adm_unlock(); return YES; }
         uint64_t generation=0,epoch=0;
         int result=rwa_texture_ticket_begin(texture,&generation,&epoch);
         if (!result) {
            _dsurf[d]=_dsurf[--_dcount];
            _tgen[_tcount]=generation; _tepoch[_tcount]=epoch; _tsurf[_tcount++]=surface;
            bg_pending_writers[n].generation=generation;
            ++bg_suspended_reticketed;
            bg_suspended_event(1);
            bg_tl_ticket(_tlcb, generation, epoch, 1);
         } else if (result == -EAGAIN) {
            _dsurf[d]=_dsurf[--_dcount];
            ++_ucount;   // deferred -> unticketed: the total stays the same
            ++bg_suspended_unticketed;
            bg_suspended_event(0);
            bg_tl_ticket(_tlcb, 0, 0, 1);
         } else {
            _dsurf[d]=_dsurf[--_dcount];
            bg_adm_unlock();
            return [self bgAdmissionReject:[NSString stringWithFormat:@"imported destination %u BEGIN refused (%d); no writes replayed",surface,result]];
         }
         bg_adm_unlock();
         return YES;
      }
      prior=bg_pending_writers[n].owner;
      // A replay-time discovery cannot wait while holding the context. An
      // uncommitted producer may depend on this caller to commit: never wait.
      if (!prior || !prior->committed || _committed) {
         bg_adm_unlock();
         return [self bgAdmissionReject:@"imported destination has an uncommitted, replay-time or unresolved owner"];
      }
      [prior retain];
      break;
   }
   if (prior) {
      bg_adm_unlock();
      // One bounded wait, outside the context lock and callback monitor. Full
      // completion also covers different devices and CPU-blit ownership.
      long timedout=dispatch_group_wait(prior->done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
      [prior release];
      if (timedout) return [self bgAdmissionReject:@"imported destination prior producer did not complete within admission deadline"];
      // Requery kernel ownership exactly once. Queue/show/retire protection may
      // still refuse it; waiting for our producer never overrides that result.
      bg_adm_lock();
      vacant=BG_MAX_PENDING_WRITERS;
      for (unsigned n=0;n<BG_MAX_PENDING_WRITERS;n++) {
         if (!bg_pending_writers[n].surface) vacant=n;
         if (bg_pending_writers[n].surface == surface) {
            bg_adm_unlock(); return [self bgAdmissionReject:@"imported destination still owned after producer completion"];
         }
      }
   }
   if (_tcount + _dcount + _ucount >= BG_MAX_WRITE_DESTINATIONS || vacant == BG_MAX_PENDING_WRITERS) {
      bg_adm_unlock(); return [self bgAdmissionReject:@"imported destination admission capacity exceeded"];
   }
   uint64_t generation=0,epoch=0;
   int result=rwa_texture_ticket_begin(texture,&generation,&epoch);
   if (result == -EAGAIN) {
      // The presenter is suspended. Encode defers the surface for one replay
      // retry; a destination first seen at replay is admitted unticketed now.
      bg_pending_writers[vacant].surface=surface;
      bg_pending_writers[vacant].owner=[_writeOwner retain];
      bg_pending_writers[vacant].generation=0;
      if (_committed) { ++_ucount; ++bg_suspended_unticketed; }
      else { _dsurf[_dcount++]=surface; ++bg_suspended_deferred; }
      bg_suspended_event(0);
      bg_tl_ticket(_tlcb, 0, 0, 1);
      bg_adm_unlock();
      return YES;
   }
   if (result) {
      bg_adm_unlock();
      return [self bgAdmissionReject:[NSString stringWithFormat:@"imported destination %u BEGIN refused (%d); no writes replayed",surface,result]];
   }
   _tgen[_tcount]=generation; _tepoch[_tcount]=epoch; _tsurf[_tcount++]=surface;
   bg_pending_writers[vacant].surface=surface;
   bg_pending_writers[vacant].owner=[_writeOwner retain];
   bg_pending_writers[vacant].generation=generation;
   bg_tl_ticket(_tlcb, generation, epoch, _committed ? 1 : 0);
   bg_adm_unlock();
   return YES;
}
- (void)bgTicketFor:(id)texture
{
   if (texture && !_admissionFailed)
      [self bgAdmitRaw:[(BGMTLTexture *)texture rwaSurfaceTexture]];
}
#ifdef BG_TL_SITE
#undef bg_lock
#define bg_lock() bg_lock_at(BG_TL_SITE(0, __LINE__))
#endif
