/* SPDX-License-Identifier: MIT */
/* Included in BGMTLCommandBuffer's implementation and the deterministic host
 * regression. Error status may be published before submission/fence retirement;
 * it is never evidence that callbacks can run. All list/readiness decisions use
 * the same monitor, and no client code runs while that monitor is held. */
- (void)addScheduledHandler:(void (^)(id))block
{
   if (!block) return;
   BOOL now;
   @synchronized (self) {
      now = _scheduledDelivered;
      if (!now) [_scheduled addObject:[[block copy] autorelease]];
   }
   if (now) block(self);
}
- (void)addCompletedHandler:(void (^)(id))block
{
   if (!block) return;
   BOOL now;
   @synchronized (self) {
      now = _completedDelivered;
      if (!now) [_completed addObject:[[block copy] autorelease]];
   }
   if (now) block(self);
}
- (void)bgDeliverHandlers:(NSMutableArray *)list completed:(BOOL)completed
{
   for (;;) {
      NSArray *handlers;
      @synchronized (self) {
         BOOL *delivered = completed ? &_completedDelivered : &_scheduledDelivered;
         if (*delivered) return;
         if (![list count]) {
            *delivered = YES;
            return;
         }
         handlers = [[list copy] autorelease];
         [list removeAllObjects];
      }
      // Registrations made during delivery (including from a handler) append to
      // the next drain, behind this snapshot. Publish readiness only once every
      // queued handler has returned, so a late handler cannot overtake the drain.
      for (void (^handler)(id) in handlers) handler(self);
   }
}
