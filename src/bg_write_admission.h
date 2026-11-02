/* SPDX-License-Identifier: MIT */
/* M7 encode-time write ownership. The registry retains a token, not the CB: CB destruction
 * removes its entries under bg_lock. An unresolved terminal entry is quarantined
 * (surface remains set, owner NULL), never a dangling object pointer. */
#define BG_MAX_WRITE_DESTINATIONS 32
#define BG_MAX_PENDING_WRITERS 1024
static struct { unsigned surface; BGWriteOwner *owner; uint64_t generation; }
   bg_pending_writers[BG_MAX_PENDING_WRITERS];

- (BOOL)bgAdmissionReject:(NSString *)reason
{
   _admissionFailed = YES;
   if (!_error) [self bgFailWith:reason code:3];
   return NO;
}
- (void)bgReleaseAdmissionOwners
{
   if (!_writeOwner) return;
   bg_lock();
   for (unsigned n=0;n<BG_MAX_PENDING_WRITERS;n++) {
      if (bg_pending_writers[n].owner != _writeOwner) continue;
      BOOL pending=NO;
      for (unsigned i=0;i<_tcount;i++)
         pending |= _tgen[i] == bg_pending_writers[n].generation;
      if (!pending) {
         [bg_pending_writers[n].owner release];
         memset(&bg_pending_writers[n],0,sizeof(bg_pending_writers[n]));
      }
   }
   bg_unlock();
}
- (void)bgQuarantineAdmissionOwners
{
   if (!_writeOwner) return;
   bg_lock();
   for (unsigned n=0;n<BG_MAX_PENDING_WRITERS;n++)
      if (bg_pending_writers[n].owner == _writeOwner) {
         [bg_pending_writers[n].owner release]; bg_pending_writers[n].owner=nil;
      }
   bg_unlock();
}
- (BOOL)bgAdmitRaw:(struct rwa_texture *)texture
{
   unsigned surface=rwa_texture_surface_id(texture);
   if (!surface) return YES;
   bg_lock();
   if (_admissionFailed) { bg_unlock(); return NO; }
   BGWriteOwner *prior=nil;
   unsigned vacant=BG_MAX_PENDING_WRITERS;
   for (unsigned n=0;n<BG_MAX_PENDING_WRITERS;n++) {
      if (!bg_pending_writers[n].surface) vacant=n;
      if (bg_pending_writers[n].surface != surface) continue;
      if (bg_pending_writers[n].owner == _writeOwner) { bg_unlock(); return YES; }
      prior=bg_pending_writers[n].owner;
      // A replay-time discovery cannot wait while holding the context. An
      // uncommitted producer may depend on this caller to commit: never wait.
      if (!prior || !prior->committed || _committed) {
         bg_unlock();
         return [self bgAdmissionReject:@"imported destination has an uncommitted, replay-time or unresolved owner"];
      }
      [prior retain];
      break;
   }
   if (prior) {
      bg_unlock();
      // One bounded wait, outside the context lock and callback monitor. Full
      // completion also covers different devices and CPU-blit ownership.
      long timedout=dispatch_group_wait(prior->done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
      [prior release];
      if (timedout) return [self bgAdmissionReject:@"imported destination prior producer did not complete within admission deadline"];
      // Requery kernel ownership exactly once. Queue/show/retire protection may
      // still refuse it; waiting for our producer never overrides that result.
      bg_lock();
      vacant=BG_MAX_PENDING_WRITERS;
      for (unsigned n=0;n<BG_MAX_PENDING_WRITERS;n++) {
         if (!bg_pending_writers[n].surface) vacant=n;
         if (bg_pending_writers[n].surface == surface) {
            bg_unlock(); return [self bgAdmissionReject:@"imported destination still owned after producer completion"];
         }
      }
   }
   if (_tcount == BG_MAX_WRITE_DESTINATIONS || vacant == BG_MAX_PENDING_WRITERS) {
      bg_unlock(); return [self bgAdmissionReject:@"imported destination admission capacity exceeded"];
   }
   uint64_t generation=0,epoch=0;
   int result=rwa_texture_ticket_begin(texture,&generation,&epoch);
   if (result) {
      bg_unlock();
      return [self bgAdmissionReject:[NSString stringWithFormat:@"imported destination %u BEGIN refused (%d); no writes replayed",surface,result]];
   }
   _tgen[_tcount]=generation; _tepoch[_tcount]=epoch; _tsurf[_tcount++]=surface;
   bg_pending_writers[vacant].surface=surface;
   bg_pending_writers[vacant].owner=[_writeOwner retain];
   bg_pending_writers[vacant].generation=generation;
   bg_unlock();
   return YES;
}
- (void)bgTicketFor:(id)texture
{
   if (texture && !_admissionFailed)
      [self bgAdmitRaw:[(BGMTLTexture *)texture rwaSurfaceTexture]];
}
