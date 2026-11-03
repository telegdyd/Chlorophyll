// SPDX-License-Identifier: MIT
// Standalone: bgmtl_ubwc_probe bg_ubwc.metallib [--reference]
// Per pattern: sample to linear, blit to linear, direct getBytes, partial
// CPU write then sample again. Every comparison reports its first bad pixel.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#include "../air/air_metal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern id bgmtl_create_device(void);
@interface NSObject (UBWCProbe)
- (struct rwa_texture *)rwaTextureAny;
@end
static unsigned passed, failed;
static MTLPixelFormat probe_format;
static void check(int ok, const char *name) {
   printf("%s %s\n", ok ? "PASS" : "FAIL", name);
   if (ok) passed++; else failed++;
}
static int finish(id<MTLCommandBuffer> cb) {
   [cb commit]; [cb waitUntilCompleted];
   if (cb.status != MTLCommandBufferStatusCompleted)
      fprintf(stderr, "command buffer: %s\n", cb.error.localizedDescription.UTF8String);
   return cb.status == MTLCommandBufferStatusCompleted;
}
static id<MTLRenderPipelineState> pipeline(id<MTLDevice> dev, id<MTLLibrary> lib,
                                           NSString *fragment, BOOL blend) {
   MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
   d.vertexFunction = [lib newFunctionWithName:@"ubwc_vs"];
   d.fragmentFunction = [lib newFunctionWithName:fragment];
   d.colorAttachments[0].pixelFormat = probe_format;
   d.colorAttachments[0].blendingEnabled = blend;
   d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
   d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
   d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
   d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
   NSError *error = nil;
   id p = [dev newRenderPipelineStateWithDescriptor:d error:&error];
   if (!p) fprintf(stderr, "pipeline: %s\n", error.localizedDescription.UTF8String);
   [d release]; return p;
}
static id<MTLTexture> target(id<MTLDevice> dev, unsigned w, unsigned h, BOOL linear,
                              IOSurfaceRef *surface) {
   MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
      probe_format width:w height:h mipmapped:NO];
   d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
   if (!linear) { d.storageMode = MTLStorageModePrivate; return [dev newTextureWithDescriptor:d]; }
   unsigned pitch = (w * 4 + 63) & ~63u;
   *surface = IOSurfaceCreate((CFDictionaryRef)@{(id)kIOSurfaceWidth:@(w),
      (id)kIOSurfaceHeight:@(h), (id)kIOSurfaceBytesPerElement:@4,
      (id)kIOSurfaceBytesPerRow:@(pitch), (id)kIOSurfacePixelFormat:
      @(probe_format == MTLPixelFormatBGRA8Unorm ? 0x42475241u : 0x52474241u)});
   d.storageMode = MTLStorageModeShared;
   return *surface ? [dev newTextureWithDescriptor:d iosurface:*surface plane:0] : nil;
}
static void draw(id<MTLCommandBuffer> cb, id<MTLTexture> dst,
                   id<MTLRenderPipelineState> p, BOOL load, BOOL partial,
                   id<MTLTexture> src) {
   MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
   rp.colorAttachments[0].texture = dst;
   rp.colorAttachments[0].loadAction = load ? MTLLoadActionLoad : MTLLoadActionClear;
   rp.colorAttachments[0].clearColor = MTLClearColorMake(0.125, 0.25, 0.5, 1);
   rp.colorAttachments[0].storeAction = MTLStoreActionStore;
   id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
   if (p) {
      [enc setRenderPipelineState:p];
      if (src) [enc setFragmentTexture:src atIndex:0];
      if (partial) [enc setScissorRect:(MTLScissorRect){3, 5, dst.width/2, dst.height/2}];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
   }
   [enc endEncoding];
}
static void compare(id<MTLTexture> texture, const unsigned char *expected,
                    unsigned w, unsigned h, const char *name) {
   size_t size = (size_t)w*h*4;
   unsigned char *got = malloc(size);
   if (!got) { check(0, "readback allocation"); return; }
   memset(got, 0x5a, size);
   [texture getBytes:got bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
   size_t i;
   for (i=0; i<size && got[i]==expected[i]; i++);
   if (i<size) printf("first bad pixel %s x=%zu y=%zu channel=%zu got=%u expected=%u\n",
      name, (i/4)%w, i/(4*w), i%4, got[i], expected[i]);
   check(i==size, name); free(got);
}
int main(int argc, char **argv) {
   @autoreleasepool {
      if (argc<2) return 2;
      BOOL reference = argc>2 && !strcmp(argv[2], "--reference");
      BOOL want = getenv("BGMTL_UBWC") && !strcmp(getenv("BGMTL_UBWC"), "1");
      id<MTLDevice> dev = bgmtl_create_device();
      NSError *error = nil;
      id<MTLLibrary> lib = [dev newLibraryWithFile:@(argv[1]) error:&error];
      id<MTLCommandQueue> queue = [dev newCommandQueue];
      const MTLPixelFormat formats[] = {MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA8Unorm};
      for (unsigned format_index=0; format_index<2; format_index++) {
      probe_format = formats[format_index];
      id<MTLRenderPipelineState> ps[] = {
         pipeline(dev,lib,@"ubwc_solid",NO), pipeline(dev,lib,@"ubwc_gradient",NO),
         pipeline(dev,lib,@"ubwc_noise",NO), pipeline(dev,lib,@"ubwc_solid",YES),
         pipeline(dev,lib,@"ubwc_sample",NO)};
      if (!dev || !lib || !queue || !ps[0] || !ps[1] || !ps[2] || !ps[3] || !ps[4]) return 1;
      const unsigned dims[][2] = {{100,2000}, {127,65}, {828,1792}};
      const char *patterns[] = {"solid", "gradient", "noise", "partial-update", "clear+draw", "blend-over-load"};
      for (unsigned dim=0; dim<3; dim++) for (unsigned pat=0; pat<6; pat++) {
         @autoreleasepool {
            unsigned w=dims[dim][0], h=dims[dim][1];
            IOSurfaceRef sr=NULL, ss=NULL, sb=NULL;
            id<MTLTexture> dst=target(dev,w,h,NO,&sr);
            id<MTLTexture> ref=target(dev,w,h,YES,&sr);
            id<MTLTexture> sample=target(dev,w,h,YES,&ss);
            id<MTLTexture> blit=target(dev,w,h,YES,&sb);
            if (!dst || !ref || !sample || !blit) return 1;
            struct rwa_dram_info info={0};
            int info_ok = !rwa_texture_dram_info([(id)dst rwaTextureAny], &info);
            printf("pattern %s fmt=%u %ux%u ubwc=%u tiled=%u\n", patterns[pat],(unsigned)probe_format,w,h,info.ubwc,info.tiled);
            check(info_ok && info.ubwc==(unsigned)want, "explicit UBWC allocation");
            id<MTLCommandBuffer> cb=[queue commandBuffer];
            id<MTLTexture> targets[]={dst,ref};
            for (unsigned t=0;t<2;t++) {
               if (pat<3) draw(cb,targets[t],ps[pat],NO,NO,nil);
               else {
                  draw(cb,targets[t],pat==4 ? nil : ps[1],NO,NO,nil);
               }
            }
            check(finish(cb), "initial render");
            if (pat>=3) {
               cb=[queue commandBuffer];
               for(unsigned t=0;t<2;t++) draw(cb,targets[t],ps[pat==5?3:2],YES,pat!=5,nil);
               check(finish(cb), "loaded second pass");
            }
            cb=[queue commandBuffer];
            draw(cb,sample,ps[4],NO,NO,dst);
            id<MTLBlitCommandEncoder> enc=[cb blitCommandEncoder];
            [enc copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
               sourceSize:MTLSizeMake(w,h,1) toTexture:blit destinationSlice:0 destinationLevel:0
               destinationOrigin:MTLOriginMake(0,0,0)];
            [enc endEncoding]; check(finish(cb), "sample and UBWC->linear blit");
            size_t size=(size_t)w*h*4;
            unsigned char *expected=malloc(size);
            if (!expected) return 1;
            [ref getBytes:expected bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
            /* Reject an all-black/shared broken reference path. Check known
             * solid output and the untouched corner of clear+draw analytically. */
            if (pat==0 || pat==4) {
               const unsigned char solid[4]={64,128,191,128};
               const unsigned char clear[4]={32,64,128,255};
               const unsigned char *rgba=pat==0 ? solid : clear;
               BOOL valid=YES;
               for(unsigned channel=0;channel<4;channel++) {
                  unsigned src=(probe_format==MTLPixelFormatBGRA8Unorm && channel<3) ? 2-channel : channel;
                  int delta=(int)expected[channel]-(int)rgba[src];
                  if(delta < -1 || delta > 1) valid=NO;
               }
               check(valid,"analytic reference pixel");
            }
            compare(sample,expected,w,h,"sample to linear");
            compare(blit,expected,w,h,"blit to linear");
            /* Save a byte-exact off baseline for comparison across processes. */
            if (reference) {
               char path[100]; snprintf(path,sizeof(path),"ubwc-%u-%u-%u.raw",(unsigned)probe_format,dim,pat);
               if (![[NSData dataWithBytes:expected length:size] writeToFile:@(path) atomically:NO]) {
                  fprintf(stderr,"cannot write reference %s\n",path); return 1;
               }
            } else {
               char path[100]; snprintf(path,sizeof(path),"ubwc-%u-%u-%u.raw",(unsigned)probe_format,dim,pat);
               NSData *baseline=[NSData dataWithContentsOfFile:@(path)];
               if (baseline.length==size) {
                  const unsigned char *bytes=baseline.bytes;
                  for(size_t i=0;i<size;i++) if(bytes[i]!=expected[i]) {
                     printf("first bad pixel UBWC-off reference x=%zu y=%zu channel=%zu got=%u expected=%u\n",
                        (i/4)%w,i/(4*w),i%4,expected[i],bytes[i]); break;
                  }
               }
               check(baseline.length==size && !memcmp(baseline.bytes,expected,size),"UBWC-off reference");
            }
            compare(dst,expected,w,h,"direct getBytes");
            cb=[queue commandBuffer]; draw(cb,sample,ps[4],NO,NO,dst);
            check(finish(cb),"sample after getBytes");
            compare(sample,expected,w,h,"cached view after getBytes");
            /* Separate target: exercise a partial CPU write while still UBWC,
             * then reuse the same texture/view after it becomes linear. */
            id<MTLTexture> cpu=target(dev,w,h,NO,&sr);
            if (!cpu) return 1;
            cb=[queue commandBuffer]; draw(cb,cpu,ps[1],NO,NO,nil); check(finish(cb),"CPU-write seed");
            cb=[queue commandBuffer]; draw(cb,sample,ps[4],NO,NO,cpu); check(finish(cb),"cache CPU-write view");
            unsigned char patch[7*9*4]; memset(patch,0x7b,sizeof(patch));
            [cpu replaceRegion:MTLRegionMake2D(1,2,7,9) mipmapLevel:0 withBytes:patch bytesPerRow:7*4];
            /* cpu seed is gradient, independently of this pattern. */
            cb=[queue commandBuffer]; draw(cb,ref,ps[1],NO,NO,nil); check(finish(cb),"CPU-write reference");
            [ref replaceRegion:MTLRegionMake2D(1,2,7,9) mipmapLevel:0 withBytes:patch bytesPerRow:7*4];
            [ref getBytes:expected bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
            cb=[queue commandBuffer]; draw(cb,sample,ps[4],NO,NO,cpu); check(finish(cb),"sample after CPU write");
            compare(sample,expected,w,h,"partial CPU write preserves rest");
            free(expected); [cpu release]; [dst release]; [ref release]; [sample release]; [blit release];
            if(sr) CFRelease(sr); if(ss) CFRelease(ss); if(sb) CFRelease(sb);
         }
      }
      for (unsigned i=0;i<5;i++) [ps[i] release];
      }
      printf("%u checks passed, %u failed\n", passed,failed);
      return failed ? 1 : 0;
   }
}
