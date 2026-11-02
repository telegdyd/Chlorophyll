// SPDX-License-Identifier: MIT
// Deterministic host regression for the runtime's actual callback implementation.
// xcrun clang -fblocks -fno-objc-arc -fsanitize=address,undefined
//   -framework Foundation callback_delivery_test.m -o callback-test && ./callback-test
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <stdio.h>

@interface CallbackCB : NSObject {
   NSMutableArray *_scheduled, *_completed;
   BOOL _scheduledDelivered, _completedDelivered;
   NSInteger _status;
}
- (void)markError;
- (NSInteger)status;
- (void)addScheduledHandler:(void (^)(id))block;
- (void)addCompletedHandler:(void (^)(id))block;
- (void)deliverScheduled;
- (void)deliverCompleted;
@end
@implementation CallbackCB
- (instancetype)init {
   self = [super init];
   if (self) { _scheduled=[NSMutableArray new]; _completed=[NSMutableArray new]; _status=2; }
   return self;
}
- (void)dealloc { [_scheduled release]; [_completed release]; [super dealloc]; }
- (void)markError { @synchronized(self) { _status=5; } }
- (NSInteger)status { @synchronized(self) { return _status; } }
#include "../src/bg_callback_delivery.h"
- (void)deliverScheduled { [self bgDeliverHandlers:_scheduled completed:NO]; }
- (void)deliverCompleted { [self bgDeliverHandlers:_completed completed:YES]; }
@end

static void wait_gate(dispatch_semaphore_t gate) {
   assert(dispatch_semaphore_wait(gate,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
}
static void record(NSMutableArray *log, NSString *value) {
   @synchronized(log) { [log addObject:value]; }
}
static void expect(NSMutableArray *log, NSArray *values) {
   @synchronized(log) { assert([log isEqualToArray:values]); }
}

static void completion_fifo(void) {
   CallbackCB *earlier=[CallbackCB new], *failed=[CallbackCB new];
   NSMutableArray *log=[NSMutableArray new];
   dispatch_queue_t q=dispatch_queue_create("callback-test.completion",DISPATCH_QUEUE_SERIAL);
   dispatch_semaphore_t earlierStarted=dispatch_semaphore_create(0), earlierGate=dispatch_semaphore_create(0);
   dispatch_semaphore_t fencePending=dispatch_semaphore_create(0), fenceGate=dispatch_semaphore_create(0);
   dispatch_semaphore_t finished=dispatch_semaphore_create(0);
   [earlier addCompletedHandler:^(id cb) { record(log,@"earlier"); }];
   [failed addCompletedHandler:^(id cb) {
      assert([cb status]==5);
      record(log,@"failed-first");
      [cb addCompletedHandler:^(id b) { record(log,@"reentrant"); }];
      dispatch_semaphore_t registered=dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
         @autoreleasepool {
            // This must acquire the monitor while the first callback is running.
            // A callback invoked under that monitor deadlocks/fails the deadline.
            [cb addCompletedHandler:^(id b) { record(log,@"other-thread"); }];
            dispatch_semaphore_signal(registered);
         }
      });
      wait_gate(registered); dispatch_release(registered);
   }];
   dispatch_async(q, ^{
      @autoreleasepool {
         dispatch_semaphore_signal(earlierStarted); wait_gate(earlierGate);
         [earlier deliverCompleted];
      }
   });
   wait_gate(earlierStarted);
   [failed markError]; // replay has failed; earlier CB and this CB's fence are pending
   dispatch_async(q, ^{
      @autoreleasepool {
         dispatch_semaphore_signal(fencePending); wait_gate(fenceGate);
         [failed deliverCompleted]; dispatch_semaphore_signal(finished);
      }
   });
   [failed addCompletedHandler:^(id cb) { record(log,@"behind-earlier"); }];
   expect(log,@[]); // Error is not evidence of completion.
   dispatch_semaphore_signal(earlierGate); wait_gate(fencePending);
   expect(log,@[@"earlier"]);
   [failed addCompletedHandler:^(id cb) { record(log,@"own-fence-pending"); }];
   expect(log,@[@"earlier"]);
   dispatch_semaphore_signal(fenceGate); wait_gate(finished);
   expect(log,(@[@"earlier",@"failed-first",@"behind-earlier",@"own-fence-pending",@"reentrant",@"other-thread"]));
   [failed addCompletedHandler:^(id cb) { record(log,@"after"); }];
   [failed deliverCompleted]; // repeated retirement is harmless
   expect(log,(@[@"earlier",@"failed-first",@"behind-earlier",@"own-fence-pending",@"reentrant",@"other-thread",@"after"]));
   assert([failed status]==5);
   [earlier release]; [failed release]; [log release];
   dispatch_release(q); dispatch_release(earlierStarted); dispatch_release(earlierGate);
   dispatch_release(fencePending); dispatch_release(fenceGate); dispatch_release(finished);
}

static void scheduled_readiness(void) {
   CallbackCB *cb=[CallbackCB new]; NSMutableArray *log=[NSMutableArray new];
   [cb markError];
   [cb addScheduledHandler:^(id b) {
      record(log,@"first");
      [b addScheduledHandler:^(id b2) { record(log,@"nested"); }];
      dispatch_semaphore_t registered=dispatch_semaphore_create(0);
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
         @autoreleasepool {
            [b addScheduledHandler:^(id b2) { record(log,@"thread"); }];
            dispatch_semaphore_signal(registered);
         }
      });
      wait_gate(registered); dispatch_release(registered);
   }];
   [cb addScheduledHandler:^(id b) { record(log,@"second"); }];
   expect(log,@[]);
   [cb deliverScheduled];
   expect(log,(@[@"first",@"second",@"nested",@"thread"]));
   [cb addScheduledHandler:^(id b) { record(log,@"after"); }];
   [cb deliverScheduled];
   expect(log,(@[@"first",@"second",@"nested",@"thread",@"after"]));
   __block BOOL completed=NO;
   [cb addCompletedHandler:^(id b) { completed=YES; }];
   assert(!completed); // scheduled delivery must not make completion ready
   [cb deliverCompleted]; assert(completed && [cb status]==5);
   [cb release]; [log release];
}

static void publication_race(void) {
   for (unsigned round=0;round<50;round++) { @autoreleasepool {
      CallbackCB *cb=[CallbackCB new]; [cb markError];
      NSMutableIndexSet *seen=[NSMutableIndexSet new];
      dispatch_group_t group=dispatch_group_create();
      for (unsigned i=0;i<64;i++)
         dispatch_group_async(group,dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{
            @autoreleasepool {
               [cb addCompletedHandler:^(id b) {
                  @synchronized(seen) { assert(![seen containsIndex:i]); [seen addIndex:i]; }
               }];
            }
         });
      [cb deliverCompleted];
      assert(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
      assert([seen count]==64 && [cb status]==5);
      [cb release]; [seen release]; dispatch_release(group);
   }}
}

int main(void) { @autoreleasepool {
   completion_fifo(); scheduled_readiness(); publication_race();
   puts("PASS: late failure handlers wait for earlier CB/own fence; scheduled readiness; reentrant/concurrent drain FIFO; publication race exactly once; Error preserved");
} }
