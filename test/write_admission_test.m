/* SPDX-License-Identifier: MIT */
/* M7 imported-write admission host test. This is the actual-method test: the
 * test object below is only the minimum BGMTLCommandBuffer/BGWriteOwner shell
 * needed by src/bg_write_admission.h, and the ticket BEGIN results are stubbed.
 *
 * The deferred cases in the second half require the display-suspended M7
 * implementation (BEGIN -EAGAIN at encode, one retry at replay, unticketed
 * admission, normal release). Against the pre-deferred header they fail at the
 * first encode -EAGAIN assertion; that is expected and is not a test bug. */
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

// Capture the display-suspended diagnostics line emitted by the header. The
// header only defines BG_LOG when the including translation unit has not.
static char bg_test_log[512];
#define BG_LOG(...) do { snprintf(bg_test_log,sizeof(bg_test_log),__VA_ARGS__); } while (0)

static pthread_mutex_t mutex;
static void bg_lock(void) { pthread_mutex_lock(&mutex); }
static void bg_unlock(void) { pthread_mutex_unlock(&mutex); }
struct rwa_texture { unsigned surface; int refused; unsigned attempts; };
static unsigned rwa_texture_surface_id(struct rwa_texture *t) { return t ? t->surface : 0; }
static uint64_t generations;
static unsigned ticket_end_calls, ticket_end_aborts;
static uint64_t ticket_end_generation, ticket_end_epoch;
static int rwa_texture_ticket_begin(struct rwa_texture *t,uint64_t *g,uint64_t *e) {
   ++t->attempts;
   if (t->refused) return t->refused;
   *g=++generations; *e=7; return 0;
}
/* Mirrors bg_ticket_end for the sealed path. Deferred/unticketed entries have
 * generation 0 and must never reach this stub. */
static int test_ticket_end(uint64_t generation,uint64_t epoch,int abort) {
   ++ticket_end_calls; ticket_end_aborts += abort ? 1 : 0;
   ticket_end_generation=generation; ticket_end_epoch=epoch;
   return 0;
}
static void bg_tl_ticket(uint32_t cb,uint64_t g,uint64_t e,int deferred) { (void)cb; (void)g; (void)e; (void)deferred; }
static void reset_ticket_end_stats(void) {
   ticket_end_calls=ticket_end_aborts=0; ticket_end_generation=ticket_end_epoch=0;
}
@interface BGMTLTexture : NSObject
- (struct rwa_texture *)rwaSurfaceTexture;
@end
@implementation BGMTLTexture
- (struct rwa_texture *)rwaSurfaceTexture { return NULL; }
@end
@interface BGWriteOwner : NSObject { @public dispatch_group_t done; BOOL committed; }
- (instancetype)initWithDone:(dispatch_group_t)group;
@end
@implementation BGWriteOwner
- (instancetype)initWithDone:(dispatch_group_t)g {
   self=[super init]; if(self) { done=g; dispatch_retain(done); } return self;
}
- (void)dealloc { dispatch_release(done); [super dealloc]; }
@end
@interface BGMTLCommandBuffer : NSObject {
 @public
   uint64_t _tgen[32],_tepoch[32]; uint32_t _tsurf[32]; unsigned _tcount;
   uint32_t _dsurf[32]; unsigned _dcount, _ucount;   // deferred, and admitted unticketed
   BOOL _admissionFailed,_committed; BGWriteOwner *_writeOwner;
   NSError *_error; dispatch_group_t _done; uint32_t _tlcb;
}
- (BOOL)bgAdmissionReject:(NSString *)reason;
- (BOOL)bgAdmitRaw:(struct rwa_texture *)texture;
- (void)bgFailWith:(NSString *)why code:(NSInteger)code;
- (void)bgReleaseAdmissionOwners;
- (void)bgQuarantineAdmissionOwners;
- (void)commitPending;
- (void)retire;
@end
@implementation BGMTLCommandBuffer
- (id)init {
   self=[super init]; if(self) { _done=dispatch_group_create(); _writeOwner=[[BGWriteOwner alloc]initWithDone:_done]; } return self;
}
- (void)dealloc {
   _tcount=0; [self bgReleaseAdmissionOwners]; [self bgQuarantineAdmissionOwners];
   [_error release]; [_writeOwner release]; dispatch_release(_done); [super dealloc];
}
- (void)bgFailWith:(NSString *)why code:(NSInteger)code {
   _error=[[NSError errorWithDomain:why code:code userInfo:nil]retain];
}
#include "../src/bg_write_admission.h"
- (void)commitPending {
   pthread_mutex_lock(&bg_adm_mutex); _committed=_writeOwner->committed=YES; pthread_mutex_unlock(&bg_adm_mutex);
   dispatch_group_enter(_done);
}
// The real retire seals each nonzero generation, then releases registry entries.
// Generation 0 is a deferred/unticketed destination: no BEGIN to seal.
- (void)retire {
   bg_lock();
   for(unsigned i=0;i<_tcount;i++) if(_tgen[i]) test_ticket_end(_tgen[i],_tepoch[i],0);
   _tcount=0; _dcount=0; _ucount=0;
   [self bgReleaseAdmissionOwners];
   bg_unlock();
   if(_committed) dispatch_group_leave(_done);
}
@end

static unsigned registry_entries(unsigned surface) {
   unsigned n=0;
   for(unsigned i=0;i<BG_MAX_PENDING_WRITERS;i++)
      if(bg_pending_writers[i].surface==surface) n++;
   return n;
}
static unsigned registry_owned(BGWriteOwner *owner) {
   unsigned n=0;
   for(unsigned i=0;i<BG_MAX_PENDING_WRITERS;i++)
      if(bg_pending_writers[i].surface && bg_pending_writers[i].owner==owner) n++;
   return n;
}
static unsigned registry_generation(unsigned surface) {
   for(unsigned i=0;i<BG_MAX_PENDING_WRITERS;i++)
      if(bg_pending_writers[i].surface==surface) return (unsigned)bg_pending_writers[i].generation;
   return ~0u;
}
static unsigned registry_total(void) {
   unsigned n=0;
   for(unsigned i=0;i<BG_MAX_PENDING_WRITERS;i++) if(bg_pending_writers[i].surface) n++;
   return n;
}
static void clear_registry(void) { memset(bg_pending_writers,0,sizeof(bg_pending_writers)); }
static void reset_suspended_stats(void) {
   bg_suspended_events=bg_suspended_deferred=bg_suspended_reticketed=bg_suspended_unticketed=0;
   memset(bg_test_log,0,sizeof(bg_test_log));
}
static const char *suspended_line(void) { return bg_test_log; }


int main(void) { @autoreleasepool {
   pthread_mutexattr_t a; pthread_mutexattr_init(&a);
   pthread_mutexattr_settype(&a,PTHREAD_MUTEX_RECURSIVE); pthread_mutex_init(&mutex,&a);
   struct rwa_texture t[40]={0}; for(unsigned i=0;i<40;i++)t[i].surface=i+1;
   clear_registry();

   /* ---------------------------------------------------------------- legacy */
   BGMTLCommandBuffer *cb=[BGMTLCommandBuffer new];
   for(unsigned i=0;i<32;i++)assert([cb bgAdmitRaw:&t[i]]);
   assert(cb->_tcount==32 && [cb bgAdmitRaw:&t[0]] && t[0].attempts==1);
   assert(![cb bgAdmitRaw:&t[32]] && cb->_admissionFailed && cb->_error && !t[32].attempts);
   [cb release];
   assert(registry_total()==0);

   BGMTLCommandBuffer *uncommitted=[BGMTLCommandBuffer new], *refused=[BGMTLCommandBuffer new];
   assert([uncommitted bgAdmitRaw:&t[0]]);
   unsigned attempts=t[0].attempts;
   assert(![refused bgAdmitRaw:&t[0]] && t[0].attempts==attempts);
   [refused release]; [uncommitted release];
   assert(registry_total()==0);

   // A committed owner retires on another thread. That thread needs the same
   // context lock; holding it over the bounded wait would make this test fail.
   BGMTLCommandBuffer *prior=[BGMTLCommandBuffer new], *next=[BGMTLCommandBuffer new];
   assert([prior bgAdmitRaw:&t[0]]); [prior commitPending];
   dispatch_async(dispatch_get_global_queue(0,0),^{ @autoreleasepool { [prior retire]; } });
   assert([next bgAdmitRaw:&t[0]] && !next->_admissionFailed);
   [prior release]; [next release];

   // Finishing our producer does not override external/display ownership.
   prior=[BGMTLCommandBuffer new]; next=[BGMTLCommandBuffer new];
   assert([prior bgAdmitRaw:&t[0]]); [prior commitPending]; t[0].refused=-EBUSY;
   dispatch_async(dispatch_get_global_queue(0,0),^{ @autoreleasepool { [prior retire]; } });
   assert(![next bgAdmitRaw:&t[0]] && next->_admissionFailed);
   [prior release]; [next release]; t[0].refused=0;

   // An unresolved producer never permits writes after a one-second deadline.
   prior=[BGMTLCommandBuffer new]; next=[BGMTLCommandBuffer new];
   assert([prior bgAdmitRaw:&t[0]]); [prior commitPending];
   attempts=t[0].attempts;
   assert(![next bgAdmitRaw:&t[0]] && t[0].attempts==attempts);
   [prior retire]; [prior release]; [next release];

   // Quarantine retains only a surface identity, never a dying CB pointer.
   cb=[BGMTLCommandBuffer new]; assert([cb bgAdmitRaw:&t[0]]);
   [cb bgQuarantineAdmissionOwners]; cb->_tcount=0; [cb release];
   next=[BGMTLCommandBuffer new]; assert(![next bgAdmitRaw:&t[0]]); [next release];
   clear_registry();

   // Bounded process registry capacity is fail-closed too.
   for(unsigned i=0;i<BG_MAX_PENDING_WRITERS;i++)bg_pending_writers[i].surface=100+i;
   cb=[BGMTLCommandBuffer new]; t[33].surface=99999;
   assert(![cb bgAdmitRaw:&t[33]] && !t[33].attempts); [cb release];
   clear_registry(); t[33].surface=34;

   /* ------------------------------------------------- deferred admission */
   /* Encode -EAGAIN then replay BEGIN succeeds: the deferred destination is
    * retried once, a real generation is stored and sealed exactly once at retire. */
   reset_ticket_end_stats(); reset_suspended_stats();
   t[0].refused=-EAGAIN; t[0].attempts=0;
   cb=[BGMTLCommandBuffer new];
   assert([cb bgAdmitRaw:&t[0]] && !cb->_admissionFailed);
   assert(cb->_tcount==0 && cb->_dcount==1 && cb->_dsurf[0]==t[0].surface);
   assert(t[0].attempts==1 && registry_entries(t[0].surface)==1);
   assert(registry_owned(cb->_writeOwner)==1 && registry_generation(t[0].surface)==0);
   assert(bg_suspended_events==1 && bg_suspended_deferred==1);
   assert(!strcmp(suspended_line(),"render tickets: display suspended: 1 deferred, 0 ticketed at replay, 0 unticketed\n"));
   [cb commitPending]; t[0].refused=0;
   bg_suspended_events=99; // force the next event to emit the summary line
   assert([cb bgAdmitRaw:&t[0]] && !cb->_admissionFailed);
   assert(t[0].attempts==2 && cb->_dcount==0 && cb->_tcount==1 && cb->_tgen[0]!=0);
   assert(registry_entries(t[0].surface)==1 && registry_generation(t[0].surface)==(unsigned)cb->_tgen[0]);
   assert(bg_suspended_reticketed==1 && bg_suspended_events==100);
   assert(!strcmp(suspended_line(),"render tickets: display suspended: 1 deferred, 1 ticketed at replay, 0 unticketed\n"));
   // A further preflight pass must reuse the ticket, not BEGIN or duplicate.
   assert([cb bgAdmitRaw:&t[0]] && t[0].attempts==2 && cb->_tcount==1);
   uint64_t sealed_generation=cb->_tgen[0];
   [cb retire];
   assert(ticket_end_calls==1 && ticket_end_aborts==0 && ticket_end_generation==sealed_generation);
   assert(ticket_end_epoch==7);
   assert(registry_total()==0);
   [cb release]; t[0].refused=0;

   /* Encode -EAGAIN then replay -EAGAIN: admitted unticketed, CB succeeds, the
    * entry is released and no generation is retired. Retry only once. */
   reset_ticket_end_stats(); reset_suspended_stats();
   t[0].refused=-EAGAIN; t[0].attempts=0;
   cb=[BGMTLCommandBuffer new];
   assert([cb bgAdmitRaw:&t[0]] && !cb->_admissionFailed);
   assert(cb->_tcount==0 && cb->_dcount==1 && registry_owned(cb->_writeOwner)==1);
   assert(bg_suspended_deferred==1);
   [cb commitPending];
   bg_suspended_events=99; // force the unticketed summary line
   assert([cb bgAdmitRaw:&t[0]] && !cb->_admissionFailed);
   assert(t[0].attempts==2 && cb->_dcount==0 && cb->_tcount==0);
   assert(registry_entries(t[0].surface)==1 && registry_generation(t[0].surface)==0);
   assert(bg_suspended_unticketed==1 && bg_suspended_events==100);
   assert(!strcmp(suspended_line(),"render tickets: display suspended: 1 deferred, 0 ticketed at replay, 1 unticketed\n"));
   // The retry budget is one per destination, even if replay preflight visits it
   // again (e.g. two recorded work items sharing a surface).
   assert([cb bgAdmitRaw:&t[0]] && !cb->_admissionFailed && t[0].attempts==2);
   [cb retire];
   assert(ticket_end_calls==0 && registry_total()==0);
   [cb release]; t[0].refused=0;

   /* Encode -EAGAIN then replay -EBUSY: explicit whole-CB failure before any
    * recorded work, with the deferred identity still owned until release. */
   reset_ticket_end_stats(); reset_suspended_stats();
   t[0].refused=-EAGAIN; t[0].attempts=0;
   cb=[BGMTLCommandBuffer new];
   assert([cb bgAdmitRaw:&t[0]] && cb->_dcount==1 && cb->_tcount==0);
   [cb commitPending]; t[0].refused=-EBUSY;
   assert(![cb bgAdmitRaw:&t[0]] && cb->_admissionFailed && cb->_error);
   assert(t[0].attempts==2 && cb->_dcount==0 && registry_owned(cb->_writeOwner)==1);
   assert(bg_suspended_reticketed==0 && bg_suspended_unticketed==0);
   // The recorded clear/dispatch is never reached when _admissionFailed is set.
   [cb retire];
   assert(ticket_end_calls==0 && registry_total()==0);
   [cb release]; t[0].refused=0;

   /* A destination first discovered at replay on -EAGAIN is admitted unticketed. */
   reset_ticket_end_stats(); reset_suspended_stats();
   t[0].refused=-EAGAIN; t[0].attempts=0;
   cb=[BGMTLCommandBuffer new]; [cb commitPending]; // mutable argument record reveals it now
   assert([cb bgAdmitRaw:&t[0]] && !cb->_admissionFailed);
   assert(cb->_tcount==0 && cb->_dcount==0 && t[0].attempts==1);
   assert(registry_owned(cb->_writeOwner)==1 && registry_generation(t[0].surface)==0);
   assert(bg_suspended_unticketed==1 && bg_suspended_deferred==0 && bg_suspended_events==1);
   assert(!strcmp(suspended_line(),"render tickets: display suspended: 0 deferred, 0 ticketed at replay, 1 unticketed\n"));
   assert([cb bgAdmitRaw:&t[0]] && t[0].attempts==1); // no second replay retry
   [cb retire];
   assert(ticket_end_calls==0 && registry_total()==0);
   [cb release]; t[0].refused=0;

   /* -ENOTSUP (tickets off) and -EBUSY remain explicit whole-CB failures. */
   {
      const int failures[]={-ENOTSUP,-EBUSY};
      for(unsigned i=0;i<sizeof(failures)/sizeof(failures[0]);i++) {
         reset_ticket_end_stats();
         t[0].refused=failures[i]; t[0].attempts=0;
         cb=[BGMTLCommandBuffer new];
         assert(![cb bgAdmitRaw:&t[0]] && cb->_admissionFailed && cb->_error);
         assert(t[0].attempts==1 && cb->_tcount==0 && cb->_dcount==0 && registry_total()==0);
         [cb release];
      }
   }
   t[0].refused=0;

   /* Deferred destinations share the same 32-destination cap. */
   reset_ticket_end_stats(); reset_suspended_stats();
   for(unsigned i=0;i<33;i++) { t[i].refused=-EAGAIN; t[i].attempts=0; }
   cb=[BGMTLCommandBuffer new];
   for(unsigned i=0;i<32;i++)assert([cb bgAdmitRaw:&t[i]] && !cb->_admissionFailed);
   assert(cb->_tcount==0 && cb->_dcount==32 && bg_suspended_deferred==32);
   assert(![cb bgAdmitRaw:&t[32]] && cb->_admissionFailed && cb->_error);
   assert(t[32].attempts==0 && cb->_dcount==32 && registry_owned(cb->_writeOwner)==32);
   [cb commitPending]; [cb retire];
   assert(ticket_end_calls==0 && registry_total()==0);
   [cb release];
   for(unsigned i=0;i<33;i++)t[i].refused=0;

   /* A second CB on a surface whose first owner is deferred but uncommitted is
    * still refused, and the first owner keeps the identity. */
   reset_ticket_end_stats(); reset_suspended_stats();
   BGMTLCommandBuffer *deferred=[BGMTLCommandBuffer new], *second=[BGMTLCommandBuffer new];
   t[0].refused=-EAGAIN; t[0].attempts=0;
   assert([deferred bgAdmitRaw:&t[0]] && deferred->_tcount==0 && deferred->_dcount==1);
   assert(registry_owned(deferred->_writeOwner)==1);
   assert(![second bgAdmitRaw:&t[0]] && second->_admissionFailed && second->_error);
   assert(t[0].attempts==1 && deferred->_dcount==1 && deferred->_tcount==0);
   assert(registry_owned(deferred->_writeOwner)==1 && registry_owned(second->_writeOwner)==0);
   [second release];
   // The original deferred CB can still retry after commit.
   [deferred commitPending]; t[0].refused=0;
   assert([deferred bgAdmitRaw:&t[0]] && deferred->_dcount==0 && deferred->_tgen[0]!=0 && t[0].attempts==2);
   [deferred retire];
   assert(ticket_end_calls==1 && registry_total()==0);
   [deferred release]; t[0].refused=0;

   /* Unticketed admissions consume the same 32-destination cap: the deferred
    * move keeps the total, a new replay destination adds one, the next fails. */
   reset_ticket_end_stats(); reset_suspended_stats();
   for(unsigned i=0;i<31;i++){ t[i].refused=-EAGAIN; t[i].attempts=0; }
   cb=[BGMTLCommandBuffer new];
   for(unsigned i=0;i<31;i++)assert([cb bgAdmitRaw:&t[i]] && !cb->_admissionFailed);
   assert(cb->_tcount==0 && cb->_dcount==31 && cb->_ucount==0);
   [cb commitPending];
   assert([cb bgAdmitRaw:&t[0]] && t[0].attempts==2);   // deferred -> unticketed
   assert(cb->_dcount==30 && cb->_ucount==1);
   t[31].refused=-EAGAIN; t[31].attempts=0;
   assert([cb bgAdmitRaw:&t[31]] && !cb->_admissionFailed);   // replay-discovered
   assert(cb->_dcount==30 && cb->_ucount==2 && t[31].attempts==1);
   t[32].refused=-EAGAIN; t[32].attempts=0;
   assert(![cb bgAdmitRaw:&t[32]] && cb->_admissionFailed && cb->_error);
   assert(t[32].attempts==0 && cb->_dcount==30 && cb->_ucount==2);
   [cb retire];
   assert(ticket_end_calls==0 && registry_total()==0);
   [cb release];
   for(unsigned i=0;i<33;i++)t[i].refused=0;

   /* A replay reticket is rare enough to log before the 100th suspended event. */
   reset_ticket_end_stats(); reset_suspended_stats();
   t[0].refused=-EAGAIN; t[0].attempts=0;
   cb=[BGMTLCommandBuffer new];
   assert([cb bgAdmitRaw:&t[0]] && cb->_dcount==1);
   assert(bg_suspended_events==1);
   [cb commitPending]; t[0].refused=0;
   assert([cb bgAdmitRaw:&t[0]] && cb->_dcount==0 && cb->_tcount==1);
   assert(bg_suspended_reticketed==1 && bg_suspended_events==2);
   assert(!strcmp(suspended_line(),"render tickets: display suspended: 1 deferred, 1 ticketed at replay, 0 unticketed\n"));
   [cb retire];
   assert(registry_total()==0);
   [cb release]; t[0].refused=0;

   /* A sealed/released producer leaves no wait behind: the same surface opens a
    * fresh generation immediately. */
   reset_ticket_end_stats(); reset_suspended_stats();
   BGMTLCommandBuffer *first=[BGMTLCommandBuffer new], *again=[BGMTLCommandBuffer new];
   t[0].refused=0; t[0].attempts=0;
   assert([first bgAdmitRaw:&t[0]] && first->_tcount==1);
   uint64_t first_generation=first->_tgen[0];
   [first commitPending]; [first retire];
   assert(ticket_end_calls==1 && registry_total()==0);
   [first release];
   assert([again bgAdmitRaw:&t[0]] && again->_tcount==1);
   assert(t[0].attempts==2 && again->_tgen[0]!=first_generation);
   [again commitPending]; [again retire];
   assert(ticket_end_calls==2 && registry_total()==0);
   [again release];

   // M8: completion releases its registry entries without bg_lock, so it never
   // waits for another command buffer's replay that holds the context.
   BGMTLCommandBuffer *done_cb=[[BGMTLCommandBuffer alloc]init];
   t[0].refused=0;
   assert([done_cb bgAdmitRaw:&t[0]] && registry_total()==1);
   [done_cb commitPending];
   dispatch_semaphore_t held=dispatch_semaphore_create(0), finish=dispatch_semaphore_create(0);
   dispatch_async(dispatch_get_global_queue(0,0),^{
      bg_lock(); dispatch_semaphore_signal(held);
      dispatch_semaphore_wait(finish,DISPATCH_TIME_FOREVER); bg_unlock();
   });
   dispatch_semaphore_wait(held,DISPATCH_TIME_FOREVER);
   dispatch_semaphore_t released=dispatch_semaphore_create(0);
   dispatch_async(dispatch_get_global_queue(0,0),^{
      done_cb->_tcount=0; [done_cb bgReleaseAdmissionOwners]; dispatch_semaphore_signal(released);
   });
   assert(!dispatch_semaphore_wait(released,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)));
   assert(registry_total()==0);
   dispatch_semaphore_signal(finish);
   bg_lock(); bg_unlock();   // the holder has let go
   dispatch_group_leave(done_cb->_done);
   [done_cb release];
   dispatch_release(held); dispatch_release(finish); dispatch_release(released);

   // M10 C: encode-time admission takes only bg_adm_mutex, so it completes while
   // another command buffer's replay holds bg_lock.
   BGMTLCommandBuffer *enc_cb=[[BGMTLCommandBuffer alloc]init];
   held=dispatch_semaphore_create(0); finish=dispatch_semaphore_create(0);
   dispatch_async(dispatch_get_global_queue(0,0),^{
      bg_lock(); dispatch_semaphore_signal(held);
      dispatch_semaphore_wait(finish,DISPATCH_TIME_FOREVER); bg_unlock();
   });
   dispatch_semaphore_wait(held,DISPATCH_TIME_FOREVER);
   dispatch_semaphore_t admitted=dispatch_semaphore_create(0);
   __block BOOL admit_ok=NO; struct rwa_texture *t0=&t[0];
   dispatch_async(dispatch_get_global_queue(0,0),^{
      admit_ok=[enc_cb bgAdmitRaw:t0]; dispatch_semaphore_signal(admitted);
   });
   assert(!dispatch_semaphore_wait(admitted,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)));
   assert(admit_ok && registry_total()==1 && enc_cb->_tcount==1);
   dispatch_semaphore_signal(finish);
   bg_lock(); bg_unlock();
   [enc_cb commitPending]; [enc_cb retire];
   [enc_cb release];
   dispatch_release(held); dispatch_release(finish); dispatch_release(admitted);

   assert(registry_total()==0);
   puts("PASS: encode admission without bg_lock; release without bg_lock; legacy admission + deferred encode/replay (ticket, unticketed, EBUSY, ENOTSUP, replay-discovered, 32 cap with unticketed, uncommitted ownership, one retry, reticket log, sealed-surface reuse, diagnostics)");
} }
