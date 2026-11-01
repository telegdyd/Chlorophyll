// SPDX-License-Identifier: MIT
// jasmine: Apple's MPSImageGaussianBlur on the unregistered BGMTLDevice, in a loop, from the shell. Pride's wallpaper
// blurs a 207x448 R8Unorm shadow this way and its jobs faulted the SMMU (FAR 41a680); this reproduces that work
// without the UI. Usage: bgmtl_mps_probe [sigma] [iterations] [width height] [zero|clamp]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern id bgmtl_create_device(void);

// Pride's ribbon pass: 4x MSAA memoryless colour and depth, resolved into a single-sample texture.
// Usage: bgmtl_mps_probe msaa render.metallib [iterations] [width height] [samples]
static int
msaa_main(int argc, char **argv)
{
   int iterations = argc > 3 ? atoi(argv[3]) : 10;
   int w = argc > 5 ? atoi(argv[4]) : 828, h = argc > 5 ? atoi(argv[5]) : 1792;
   int samples = argc > 6 ? atoi(argv[6]) : 4;
   const char *opt = argc > 7 ? argv[7] : "";   // private: MSAA textures private, not memoryless; nodepth: no depth
   BOOL nodepth = strstr(opt, "nodepth") != NULL;
   if (strstr(opt, "debug")) { setenv("FD_MESA_DEBUG", "perf,msgs", 1); setenv("BGMTL_TRACE", "1", 1); setenv("IR3_SHADER_DEBUG", "disasm", 1); }
   id<MTLDevice> dev = bgmtl_create_device();
   if (!dev) { printf("no device\n"); return 3; }
   id<MTLCommandQueue> q = [dev newCommandQueue];
   NSError *err = nil;
   id<MTLLibrary> lib = [dev newLibraryWithFile:[NSString stringWithUTF8String:argv[2]] error:&err];
   MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
   pd.vertexFunction = [lib newFunctionWithName:@"bg_vs"];
   pd.fragmentFunction = [lib newFunctionWithName:@"bg_fs_color"];
   pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
   pd.depthAttachmentPixelFormat = nodepth ? MTLPixelFormatInvalid : MTLPixelFormatDepth32Float;
   pd.rasterSampleCount = samples;
   id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
   if (!pso) { printf("no pipeline: %s\n", [[err localizedDescription] UTF8String]); return 3; }
   MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
   dd.depthCompareFunction = MTLCompareFunctionLess;
   dd.depthWriteEnabled = YES;
   id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
   MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:w height:h mipmapped:NO];
   td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
   td.storageMode = MTLStorageModeShared;
   id<MTLTexture> resolve = [dev newTextureWithDescriptor:td];
   td.textureType = samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
   td.sampleCount = samples;
   td.usage = MTLTextureUsageRenderTarget | (strstr(opt, "msread") ? MTLTextureUsageShaderRead : 0);
   td.storageMode = strstr(opt, "private") ? MTLStorageModePrivate : MTLStorageModeMemoryless;
   id<MTLTexture> msaa = [dev newTextureWithDescriptor:td];
   td.pixelFormat = MTLPixelFormatDepth32Float;
   id<MTLTexture> depth = [dev newTextureWithDescriptor:td];
   // one triangle covering the middle, red
   float tri[3][8] = { { -0.8f, -0.8f, 0.5f, 1, 1, 0, 0, 1 }, { 0.8f, -0.8f, 0.5f, 1, 1, 0, 0, 1 },
                       { 0, 0.8f, 0.5f, 1, 1, 0, 0, 1 } };
   id<MTLBuffer> vb = [dev newBufferWithBytes:tri length:sizeof(tri) options:MTLResourceStorageModeShared];
   printf("== MSAA %dx pass %dx%d (memoryless colour+depth, resolve), %d iterations\n", samples, w, h, iterations);
   int failed = 0;
   for (int i = 0; i < iterations; i++) {
      @autoreleasepool {
         MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
         rp.colorAttachments[0].texture = samples > 1 ? msaa : resolve;
         rp.colorAttachments[0].resolveTexture = samples > 1 ? resolve : nil;
         rp.colorAttachments[0].loadAction = MTLLoadActionClear;
         rp.colorAttachments[0].storeAction = samples <= 1 ? MTLStoreActionStore :
                                              strstr(opt, "msread") ? MTLStoreActionStoreAndMultisampleResolve : MTLStoreActionMultisampleResolve;
         rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
         rp.depthAttachment.texture = nodepth ? nil : depth;
         rp.depthAttachment.loadAction = MTLLoadActionClear;
         rp.depthAttachment.storeAction = MTLStoreActionDontCare;
         rp.depthAttachment.clearDepth = 1.0;
         id<MTLCommandBuffer> cb = [q commandBuffer];
         id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
         [enc setRenderPipelineState:pso];
         if (!nodepth) [enc setDepthStencilState:ds];
         [enc setVertexBuffer:vb offset:0 atIndex:0];
         [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
         [enc endEncoding];
         NSDate *t0 = [NSDate date];
         [cb commit];
         [cb waitUntilCompleted];
         double ms = -[t0 timeIntervalSinceNow] * 1000;
         printf("  iteration %d: status %ld, %.1f ms%s%s\n", i, (long)[cb status], ms, [cb error] ? " " : "",
                [cb error] ? [[[cb error] localizedDescription] UTF8String] : "");
         if ([cb status] != MTLCommandBufferStatusCompleted && ++failed >= 3) break;
      }
   }
   if (strstr(opt, "msread")) {
      // the samples of the centre and corner texels, read by a kernel from the multisample attachment itself
      id<MTLLibrary> klib = [dev newLibraryWithFile:@"/usr/local/p/bg_kernels2.metallib" error:&err];
      id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:[klib newFunctionWithName:@"bg_ms_read"] error:&err];
      if (!cps) { printf("no ms read pipeline: %s\n", [[err localizedDescription] UTF8String]); return 3; }
      for (int k = 0; k < 2; k++) {
         uint32_t at[2] = { k ? 2 : w / 2, k ? 2 : h / 2 };
         id<MTLBuffer> out = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
         id<MTLCommandBuffer> cb = [q commandBuffer];
         id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
         [ce setComputePipelineState:cps];
         [ce setTexture:msaa atIndex:0];
         [ce setBuffer:out offset:0 atIndex:0];
         [ce setBytes:at length:sizeof(at) atIndex:1];
         [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 1, 1)];
         [ce endEncoding];
         [cb commit];
         [cb waitUntilCompleted];
         const float *f = [out contents];
         printf("  %s samples (status %ld):", k ? "corner" : "centre", (long)[cb status]);
         for (int s = 0; s < 4; s++) printf(" (%.2f %.2f %.2f %.2f)", f[s * 4], f[s * 4 + 1], f[s * 4 + 2], f[s * 4 + 3]);
         printf("\n");
      }
   }
   if (strstr(opt, "rdk")) {
      // the resolve target read by a kernel on the GPU, not by the CPU: stale CPU caches or a blit that wrote nothing
      id<MTLLibrary> klib = [dev newLibraryWithFile:@"/usr/local/p/bg_kernels2.metallib" error:&err];
      id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:[klib newFunctionWithName:@"bg_tex_read"] error:&err];
      id<MTLBuffer> out = [dev newBufferWithLength:(NSUInteger)w * h * 16 options:MTLResourceStorageModeShared];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
      [ce setComputePipelineState:cps];
      [ce setTexture:resolve atIndex:0];
      [ce setBuffer:out offset:0 atIndex:0];
      [ce dispatchThreadgroups:MTLSizeMake((w + 7) / 8, (h + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
      [ce endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      const float *f = [out contents];
      const float *c = f + ((h / 2) * w + w / 2) * 4, *k = f + (2 * w + 2) * 4;
      printf("  resolve by kernel (status %ld): centre (%.2f %.2f %.2f %.2f) corner (%.2f %.2f %.2f %.2f)\n", (long)[cb status],
             c[0], c[1], c[2], c[3], k[0], k[1], k[2], k[3]);
   }
   uint32_t px[3];
   [resolve getBytes:&px[0] bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(w / 2, h / 2, 1, 1) mipmapLevel:0];
   [resolve getBytes:&px[1] bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(2, 2, 1, 1) mipmapLevel:0];
   printf("  centre %08x corner %08x (want red ffff0000-ish and blue ff0000ff)\n", px[0], px[1]);
   printf("== result: %d failed\n", failed);
   return failed ? 1 : 0;
}

int
main(int argc, char **argv)
{
   if (argc > 2 && !strcmp(argv[1], "msaa")) {
      @autoreleasepool { return msaa_main(argc, argv); }
   }
   @autoreleasepool {
      float sigma = argc > 1 ? atof(argv[1]) : 20.0f;
      int iterations = argc > 2 ? atoi(argv[2]) : 50;
      int w = argc > 4 ? atoi(argv[3]) : 207, h = argc > 4 ? atoi(argv[4]) : 448;
      id<MTLDevice> dev = bgmtl_create_device();
      if (!dev) { printf("no device\n"); return 3; }
      id<MTLCommandQueue> q = [dev newCommandQueue];
      MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                    width:w height:h mipmapped:NO];
      d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
      d.storageMode = MTLStorageModeShared;
      id<MTLTexture> src = [dev newTextureWithDescriptor:d], dst = [dev newTextureWithDescriptor:d];
      uint8_t *pix = malloc((size_t)w * h);
      for (int y = 0; y < h; y++)
         for (int x = 0; x < w; x++) pix[y * w + x] = (x > w / 3 && x < 2 * w / 3 && y > h / 3 && y < 2 * h / 3) ? 255 : 0;
      [src replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pix bytesPerRow:w];
      MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] initWithDevice:dev sigma:sigma];
      blur.edgeMode = argc > 5 && !strcmp(argv[5], "clamp") ? MPSImageEdgeModeClamp : MPSImageEdgeModeZero;
      printf("== MPS blur sigma %.1f on %dx%d R8Unorm, %d iterations\n", sigma, w, h, iterations);
      int failed = 0;
      for (int i = 0; i < iterations; i++) {
         @autoreleasepool {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            [blur encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst];
            [cb commit];
            [cb waitUntilCompleted];
            if ([cb status] != MTLCommandBufferStatusCompleted) {
               printf("  iteration %d: status %ld %s\n", i, (long)[cb status],
                      [cb error] ? [[[cb error] localizedDescription] UTF8String] : "");
               if (++failed >= 3) break;
            }
         }
      }
      [dst getBytes:pix bytesPerRow:w fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
      printf("  centre %u, edge %u, corner %u\n", pix[(h / 2) * w + w / 2], pix[(h / 3) * w + w / 2], pix[0]);
      printf("== result: %d failed\n", failed);
      return failed ? 1 : 0;
   }
}
