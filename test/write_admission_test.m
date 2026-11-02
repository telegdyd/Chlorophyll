/* SPDX-License-Identifier: MIT */
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

static pthread_mutex_t mutex;
static void bg_lock(void) { pthread_mutex_lock(&mutex); }
static void bg_unlock(void) { pthread_mutex_unlock(&mutex); }
struct rwa_texture { unsigned surface; int refused; unsigned attempts; };
static unsigned rwa_texture_surface_id(struct rwa_texture *t) { return t ? t->surface : 0; }
static uint64_t generations;
static int rwa_texture_ticket_begin(struct rwa_texture *t,uint64_t *g,uint64_t *e) {
   ++t->attempts;
   if (t->refused) return t->refused;
   *g=++generations; *e=7; return 0;
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
   BOOL _admissionFailed,_committed; BGWriteOwner *_writeOwner;
   NSError *_error; dispatch_group_t _done;
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
   bg_lock(); _committed=_writeOwner->committed=YES; dispatch_group_enter(_done); bg_unlock();
}
- (void)retire {
   bg_lock(); _tcount=0; [self bgReleaseAdmissionOwners]; bg_unlock(); dispatch_group_leave(_done);
}
@end

int main(void) { @autoreleasepool {
   pthread_mutexattr_t a; pthread_mutexattr_init(&a);
   pthread_mutexattr_settype(&a,PTHREAD_MUTEX_RECURSIVE); pthread_mutex_init(&mutex,&a);
   struct rwa_texture t[34]={0}; for(unsigned i=0;i<34;i++)t[i].surface=i+1;
   BGMTLCommandBuffer *cb=[BGMTLCommandBuffer new];
   for(unsigned i=0;i<32;i++)assert([cb bgAdmitRaw:&t[i]]);
   assert(cb->_tcount==32 && [cb bgAdmitRaw:&t[0]] && t[0].attempts==1);
   assert(![cb bgAdmitRaw:&t[32]] && cb->_admissionFailed && cb->_error && !t[32].attempts);
   [cb release];
   BGMTLCommandBuffer *uncommitted=[BGMTLCommandBuffer new], *refused=[BGMTLCommandBuffer new];
   assert([uncommitted bgAdmitRaw:&t[0]]);
   assert(![refused bgAdmitRaw:&t[0]] && t[0].attempts==2);
   [refused release]; [uncommitted release];
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
   unsigned attempts=t[0].attempts;
   assert(![next bgAdmitRaw:&t[0]] && t[0].attempts==attempts);
   [prior retire]; [prior release]; [next release];
   // Quarantine retains only a surface identity, never a dying CB pointer.
   cb=[BGMTLCommandBuffer new]; assert([cb bgAdmitRaw:&t[0]]);
   [cb bgQuarantineAdmissionOwners]; cb->_tcount=0; [cb release];
   next=[BGMTLCommandBuffer new]; assert(![next bgAdmitRaw:&t[0]]); [next release];
   memset(bg_pending_writers,0,sizeof(bg_pending_writers));
   // Bounded process registry capacity is fail-closed too.
   for(unsigned i=0;i<BG_MAX_PENDING_WRITERS;i++)bg_pending_writers[i].surface=100+i;
   cb=[BGMTLCommandBuffer new]; t[33].surface=99999;
   assert(![cb bgAdmitRaw:&t[33]] && !t[33].attempts); [cb release];
   memset(bg_pending_writers,0,sizeof(bg_pending_writers));
   puts("PASS: 32 destinations, dedup, cap, uncommitted refusal, pending retry outside lock, external refusal, timeout, quarantine, registry bound");
} }
