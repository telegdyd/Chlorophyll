// SPDX-License-Identifier: MIT
// Isolated IOSurface ticket/epoch test. Explicit --display-epochs permits bounded
// display off/on transitions; use under the shared phone lock on a temporary
// M7 kernel. Does not submit a display record or install any libraries.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../air/air_metal.h"

// IOKit is in the iPhoneOS SDK; its user-client headers are not.
typedef mach_port_t io_service_t, io_connect_t;
typedef int IOReturn;
extern const mach_port_t kIOMainPortDefault;
extern CFMutableDictionaryRef IOServiceMatching(const char *);
extern io_service_t IOServiceGetMatchingService(mach_port_t,CFMutableDictionaryRef);
extern IOReturn IOServiceOpen(io_service_t,task_port_t,uint32_t,io_connect_t *);
extern IOReturn IOServiceClose(io_connect_t);
extern IOReturn IOObjectRelease(mach_port_t);
extern IOReturn IOConnectCallScalarMethod(io_connect_t,uint32_t,const uint64_t *,uint32_t,uint64_t *,uint32_t *);

extern id bgmtl_create_device(void);
@interface NSObject (TicketProbe)
- (struct rwa_device *)rwa;
- (struct rwa_texture *)rwaSurfaceTexture;
@end

#define KIO_RETURN_ABORTED ((int)0xe00002eb)   // kIOReturnAborted
static io_connect_t framebuffer;
static int power(unsigned state)
{
   uint64_t in=state;
   return IOConnectCallScalarMethod(framebuffer,12,&in,1,NULL,NULL);
}
static int clear(struct rwa_device *dev, struct rwa_texture *texture,
                 uint64_t generation, uint64_t epoch, int cancel_after_submit)
{
   char why[256]={0};
   struct rwa_clear c={.color=&texture,.color_count=1,.color_mask=1};
   c.color_value[0][1]=1; c.color_value[0][3]=1;
   if (rwa_render_clear(dev,&c,why,sizeof(why))) return 1;
   struct rwa_fence *f=rwa_flush(dev);
   uint32_t seq=rwa_fence_seqno(dev,f);
   int result=!seq;
   if (cancel_after_submit) result |= power(0) || power(1);
   int seal=rwa_ticket_end(dev,generation,epoch,0,seq);
   if (cancel_after_submit) {
      // j0127: a cancelled frame's proven submit is ACKed by SEAL. The same
      // seqno is idempotent; a different one is a stale rejection, not Busy.
      int again=rwa_ticket_end(dev,generation,epoch,0,seq);
      int stale=rwa_ticket_end(dev,generation,epoch,0,seq+1);
      printf("  cancelled ACK: repeat 0x%x stale 0x%x\n",again,stale);
      result |= again != 0;
      result |= stale != KIO_RETURN_ABORTED;
   }
   int wait=rwa_fence_wait(dev,f,why,sizeof(why));
   printf("  generation %llu epoch %llu submit %u: seal 0x%x wait %d\n",
          (unsigned long long)generation,(unsigned long long)epoch,seq,seal,wait);
   // A baseline failure must not leave a pending backing retain behind.
   if (seal && !wait) rwa_ticket_end(dev,generation,epoch,1,0);
   rwa_fence_release(dev,f);
   return result || seal || wait;
}

int main(int argc,char **argv)
{
   if (argc!=2 || strcmp(argv[1],"--display-epochs")) return 2;
   setvbuf(stdout,NULL,_IONBF,0);
   @autoreleasepool {
      io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleCLCD"));
      if (!service) { puts("FAIL: no AppleCLCD"); return 1; }
      IOReturn opened=IOServiceOpen(service,mach_task_self(),0,&framebuffer);
      IOObjectRelease(service);
      if (opened) { printf("FAIL: framebuffer open 0x%x\n",opened); return 1; }
      int failed=0;
      id device=bgmtl_create_device();
      IOSurfaceRef surface=IOSurfaceCreate((CFDictionaryRef)@{
         (id)kIOSurfaceWidth:@32,(id)kIOSurfaceHeight:@32,
         (id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfaceBytesPerRow:@128,
         (id)kIOSurfacePixelFormat:@(0x42475241u)});
      MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
      d.usage=MTLTextureUsageRenderTarget; d.storageMode=MTLStorageModeShared;
      id texture=surface ? [device newTextureWithDescriptor:d iosurface:surface plane:0] : nil;
      struct rwa_device *dev=[device rwa];
      struct rwa_texture *t=[texture rwaSurfaceTexture];
      if (!dev || !t) failed=1;
      for (unsigned scenario=0;!failed && scenario<3;scenario++) {
         uint64_t generation=0,epoch=0,other=0,other_epoch=0;
         int begin=rwa_texture_ticket_begin(t,&generation,&epoch);
         printf("scenario %u begin %d\n",scenario,begin);
         if (begin) { failed=1; break; }
         if (!rwa_texture_ticket_begin(t,&other,&other_epoch)) {
            rwa_ticket_end(dev,other,other_epoch,1,0); failed=1;
         }
         if (scenario==1) failed |= power(0) || power(1); // before replay/submit
         failed |= clear(dev,t,generation,epoch,scenario==2);
         if (failed) break;
         // Recover onto the SAME backing, rather than hiding a stuck generation
         // by allocating another surface. New generation must seal and read back.
         uint64_t next=0,next_epoch=0;
         if (rwa_texture_ticket_begin(t,&next,&next_epoch)) { failed=1; break; }
         if (scenario && next_epoch==epoch) failed=1;
         failed |= next<=generation || clear(dev,t,next,next_epoch,0);
         uint8_t pixels[32*32*4];
         [texture getBytes:pixels bytesPerRow:128 fromRegion:MTLRegionMake2D(0,0,32,32) mipmapLevel:0];
         for (unsigned i=0;i<sizeof(pixels);i++) if (pixels[i] != (i%4==1 || i%4==3 ? 255 : 0)) failed=1;
      }
      // Always restore display-on, including failed or baseline experiments.
      failed |= power(1)!=0;
      [texture release]; if (surface) CFRelease(surface); [device release];
      IOServiceClose(framebuffer);
      puts(failed ? "FAIL: ticket epoch recovery" : "PASS: normal/pre-submit/post-submit epochs, pending reuse rejection, same-backing recovery pixels, cancelled ACK idempotence");
      return failed ? 1 : 0;
   }
}
