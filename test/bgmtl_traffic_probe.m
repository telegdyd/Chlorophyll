// SPDX-License-Identifier: MIT
// M6: deterministic dual-attachment Load/Clear, Store/Store workload.
// Compare the SAME pair with FD_MESA_DEBUG=sysmem and SWEETCA_GMEM=0/2.
// Commit/completion wall time includes CPU, scheduling and GPU work; not bus bytes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
extern id bgmtl_create_device(void);

int main(int argc, char **argv)
{
   @autoreleasepool {
      if (argc < 2) return 2;
      unsigned iterations = argc > 2 ? (unsigned)atoi(argv[2]) : 40;
      if (iterations < 6 || iterations > 120) return 2;
      enum { W = 828, H = 1792 };
      id<MTLDevice> dev = bgmtl_create_device();
      NSError *error = nil;
      id<MTLLibrary> lib = [dev newLibraryWithFile:@(argv[1]) error:&error];
      MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
      pd.vertexFunction = [lib newFunctionWithName:@"bg_vs"];
      pd.fragmentFunction = [lib newFunctionWithName:@"bg_fs_color"];
      pd.colorAttachments[0].pixelFormat = pd.colorAttachments[1].pixelFormat = MTLPixelFormatBGRA8Unorm;
      // The shader has only color0. Explicitly preserve color1 during draws;
      // its green clear still must be stored and visible after completion.
      pd.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
      id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
      id<MTLCommandQueue> queue = [dev newCommandQueue];
      MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
         width:W height:H mipmapped:NO];
      td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      id<MTLTexture> a = [dev newTextureWithDescriptor:td], b = [dev newTextureWithDescriptor:td];
      static const float quad[] = {
         -1,-1,0,1, 1,0,0,1, 1,-1,0,1, 1,0,0,1, -1,1,0,1, 1,0,0,1,
          1,-1,0,1, 1,0,0,1, 1,1,0,1, 1,0,0,1, -1,1,0,1, 1,0,0,1 };
      id<MTLBuffer> vb = [dev newBufferWithBytes:quad length:sizeof(quad) options:0];
      uint32_t *pixels = malloc((size_t)W*H*4);
      if (!pipeline || !queue || !a || !b || !vb || !pixels) {
         fprintf(stderr, "traffic setup failed: %s\n", error.localizedDescription.UTF8String);
         free(pixels); return 1;
      }
      for (unsigned i=0; i<W*H; i++) pixels[i] = 0xff0000ff; // blue, BGRA
      [a replaceRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0 withBytes:pixels bytesPerRow:W*4];
      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
      rp.colorAttachments[0].texture = a;
      rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
      rp.colorAttachments[0].storeAction = MTLStoreActionStore;
      rp.colorAttachments[1].texture = b;
      rp.colorAttachments[1].loadAction = MTLLoadActionClear;
      rp.colorAttachments[1].storeAction = MTLStoreActionStore;
      rp.colorAttachments[1].clearColor = MTLClearColorMake(0,1,0,1);
      unsigned bad = 0;
      for (unsigned i=0; i<iterations; i++) { @autoreleasepool {
         uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC);
         id<MTLCommandBuffer> cb = [queue commandBuffer];
         id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
         [enc setRenderPipelineState:pipeline]; [enc setVertexBuffer:vb offset:0 atIndex:0];
         // Alternate damage to catch preservation and target-reuse mistakes.
         unsigned width = i&1 ? W/2 : W/4;
         [enc setScissorRect:(MTLScissorRect){0,0,width,H}];
         [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
         [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
         printf("M6_LOOP %u %llu\n",i,(unsigned long long)(clock_gettime_nsec_np(CLOCK_MONOTONIC)-start));
         if (cb.status != MTLCommandBufferStatusCompleted) { bad++; break; }
      }}
      for (unsigned attachment=0; attachment<2; attachment++) {
         [(attachment ? b : a) getBytes:pixels bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
         for (unsigned y=0; y<H; y++) for (unsigned x=0; x<W; x++) {
            uint32_t want = attachment ? 0xff00ff00 : x<W/2 ? 0xffff0000 : 0xff0000ff;
            if (pixels[y*W+x] != want) {
               if (bad < 4) printf("M6_MISMATCH attachment=%u x=%u y=%u got=%08x want=%08x\n",
                  attachment,x,y,pixels[y*W+x],want);
               bad++;
            }
         }
      }
      printf("M6_PIXELS %u wrong / %u pixels\n",bad,2*W*H);
      free(pixels); [vb release]; [a release]; [b release];
      [queue release]; [pipeline release]; [pd release]; [lib release];
      return bad ? 1 : 0;
   }
}
