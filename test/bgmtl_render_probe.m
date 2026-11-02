// SPDX-License-Identifier: MIT
// Spike 3: textures, samplers and a render pass on BGMTLDevice (test process only, nothing registered).
//   bgmtl_render_probe KERNELS.metallib RENDER.metallib
// P1-P3 compute with textures (read, sample through a sampler, write), P4 a coloured triangle with analytic pixel checks,
// P5 a textured quad (nearest sampler) against the texture magnified and flipped by Metal's rules.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef BGMTL_REGISTERED_PROBE
// jasmine: this executable links only Apple's frameworks, never libbgmtl.
#include <mach-o/dyld.h>
#define bgmtl_create_device MTLCreateSystemDefaultDevice
#else
extern id bgmtl_create_device(void);
#endif

static int g_pass, g_fail;
#define CHECK(cond, ...) do { if (cond) { g_pass++; } else { g_fail++; printf("  FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static id g_dev, g_queue;

@interface NSObject (BGNoCopyProbe)
- (id)newTextureWithBytesNoCopy:(void *)bytes length:(NSUInteger)length
                   descriptor:(MTLTextureDescriptor *)descriptor
                  deallocator:(void (^)(void *, NSUInteger))deallocator;
@end

static id
load_lib(const char *path)
{
   NSData *d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
   if (!d) { printf("cannot read %s\n", path); return nil; }
   dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
   NSError *e = nil;
   id lib = [g_dev newLibraryWithData:dd error:&e];
   if (!lib) printf("newLibraryWithData(%s): %s\n", path, e ? [[e localizedDescription] UTF8String] : "?");
   return lib;
}

static id
compute_pso(id lib, const char *fn)
{
   id f = [lib newFunctionWithName:[NSString stringWithUTF8String:fn]];
   NSError *e = nil;
   id p = f ? [g_dev newComputePipelineStateWithFunction:f error:&e] : nil;
   if (!p) printf("  compute pipeline %s: %s\n", fn, e ? [[e localizedDescription] UTF8String] : "no function");
   return p;
}

static id
tex2d(NSUInteger fmt, NSUInteger w, NSUInteger h, NSUInteger usage)
{
   MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)fmt width:w height:h mipmapped:NO];
   d.usage = usage;
   d.storageMode = MTLStorageModeShared;
   return [g_dev newTextureWithDescriptor:d];
}

static BOOL
run(id cb, const char *what)
{
   [cb commit];
   [cb waitUntilCompleted];
   printf("  %s: status=%ld%s%s\n", what, (long)[cb status], [cb error] ? " error=" : "", [cb error] ? [[[cb error] localizedDescription] UTF8String] : "");
   return [cb status] == 4;
}

int
main(int argc, char **argv)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   @autoreleasepool {
#ifdef BGMTL_REGISTERED_PROBE
      if (argc == 2 && (!strcmp(argv[1], "--expect-stock") || !strcmp(argv[1], "--expect-inert"))) {
         id dev = MTLCreateSystemDefaultDevice();
         BOOL stock = !dev || strcmp(object_getClassName(dev), "BGMTLDevice");
         BOOL inserted = NO;
         for (uint32_t i = 0; i < _dyld_image_count(); i++)
            if (strstr(_dyld_get_image_name(i), "/bgmtl_inject.dylib")) inserted = YES;
         BOOL ok = stock && (strcmp(argv[1], "--expect-inert") || inserted);
         printf("registration gate: device=%s inserted=%d %s\n", dev ? object_getClassName(dev) : "nil", inserted, ok ? "PASS" : "FAIL");
         [dev release];
         return ok ? 0 : 1;
      }
#endif
      // jasmine: --bb as a third argument runs the suite in compositor mode (BGMTL_BB: drawables drawn through a shadow)
      for (int i=3; i<argc; i++) {
         if (!strcmp(argv[i], "--bb")) setenv("BGMTL_BB", "1", 1);
         if (!strcmp(argv[i], "--upload-cache")) setenv("BGMTL_NOCOPY_CACHE", "1", 1);
      }
      if (argc < 3) { printf("usage: bgmtl_render_probe kernels.metallib render.metallib [--bb] [--upload-cache]\n"); return 2; }
      printf("== BGMTLDevice textures/render probe (iOS %s)\n", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);
      g_dev = bgmtl_create_device();
#ifdef BGMTL_REGISTERED_PROBE
      id again = MTLCreateSystemDefaultDevice();
      BOOL registered = g_dev && !strcmp(object_getClassName(g_dev), "BGMTLDevice") && again == g_dev && [g_dev registryID] == 0x10000b512ULL;
      printf("system default registration: class=%s stable=%d registry=%llx %s\n", g_dev ? object_getClassName(g_dev) : "nil", again == g_dev, (unsigned long long)[g_dev registryID], registered ? "PASS" : "FAIL");
      [again release];
      if (!registered) return 4;
#endif
      g_queue = [g_dev newCommandQueue];
      id klib = load_lib(argv[1]), rlib = load_lib(argv[2]);
      if (!g_dev || !g_queue || !klib || !rlib) return 3;

      // ---- P1: texture read in a kernel (RGBA32Float 8x8) ----
      printf("== P1 bg_tex_read\n");
      {
         id pso = compute_pso(klib, "bg_tex_read");
         id t = tex2d(MTLPixelFormatRGBA32Float, 8, 8, MTLTextureUsageShaderRead);
         id out = [g_dev newBufferWithLength:8 * 8 * 16 options:0];
         if (pso && t && out) {
            float px[8 * 8 * 4];
            for (int i = 0; i < 64; i++) { px[i * 4] = i; px[i * 4 + 1] = 100 + i; px[i * 4 + 2] = -i; px[i * 4 + 3] = 0.25f; }
            [t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:px bytesPerRow:8 * 16];
            memset([out contents], 0xff, 8 * 8 * 16);
            id cb = [g_queue commandBuffer];
            id e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso];
            [e setTexture:t atIndex:0];
            [e setBuffer:out offset:0 atIndex:0];
            [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [e endEncoding];
            CHECK(run(cb, "bg_tex_read"), "did not complete");
            unsigned bad = 0;
            float *o = [out contents];
            for (int i = 0; i < 64 * 4; i++) if (o[i] != px[i]) bad++;
            CHECK(bad == 0, "bg_tex_read: %u of 256 floats wrong", bad);
            printf("  %u of 256 floats correct\n", 256 - bad);
         } else { g_fail++; printf("  setup failed\n"); }
      }

      // ---- P2: sample through a sampler (RGBA8Unorm 4x4, nearest) ----
      printf("== P2 bg_tex_sample (nearest sampler)\n");
      {
         id pso = compute_pso(klib, "bg_tex_sample");
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = MTLSamplerMinMagFilterNearest; sd.magFilter = MTLSamplerMinMagFilterNearest;
         sd.sAddressMode = MTLSamplerAddressModeClampToEdge; sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         id out = [g_dev newBufferWithLength:4 * 4 * 16 options:0];
         if (pso && t && smp && out) {
            uint8_t px[4 * 4 * 4];
            for (int i = 0; i < 16; i++) { px[i * 4] = i * 16; px[i * 4 + 1] = 255 - i * 16; px[i * 4 + 2] = i; px[i * 4 + 3] = 255; }
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
            id cb = [g_queue commandBuffer];
            id e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso];
            [e setTexture:t atIndex:0]; [e setSamplerState:smp atIndex:0]; [e setBuffer:out offset:0 atIndex:0];
            [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)];
            [e endEncoding];
            CHECK(run(cb, "bg_tex_sample"), "did not complete");
            unsigned bad = 0;
            float *o = [out contents];
            for (int i = 0; i < 16; i++)
               for (int c = 0; c < 4; c++) if (fabsf(o[i * 4 + c] - px[i * 4 + c] / 255.0f) > 1e-3f) bad++;
            CHECK(bad == 0, "bg_tex_sample: %u of 64 wrong", bad);
            printf("  %u of 64 floats correct\n", 64 - bad);
         } else { g_fail++; printf("  setup failed (pso=%d t=%d smp=%d)\n", pso != nil, t != nil, smp != nil); }
      }

      // ---- P3: write a texture from a kernel, read it back ----
      printf("== P3 bg_tex_write\n");
      {
         id pso = compute_pso(klib, "bg_tex_write");
         id t = tex2d(MTLPixelFormatRGBA32Float, 16, 16, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
         if (pso && t) {
            id cb = [g_queue commandBuffer];
            id e = [cb computeCommandEncoder];
            [e setComputePipelineState:pso];
            [e setTexture:t atIndex:0];
            [e dispatchThreadgroups:MTLSizeMake(2, 2, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [e endEncoding];
            CHECK(run(cb, "bg_tex_write"), "did not complete");
            float back[16 * 16 * 4];
            [t getBytes:back bytesPerRow:16 * 16 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
            unsigned bad = 0;
            for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
               float *p = back + (y * 16 + x) * 4;
               if (fabsf(p[0] - x / 16.0f) > 1e-6f || fabsf(p[1] - y / 16.0f) > 1e-6f || p[2] != 0.5f || p[3] != 1.0f) bad++;
            }
            CHECK(bad == 0, "bg_tex_write: %u of 256 texels wrong", bad);
            printf("  %u of 256 texels correct\n", 256 - bad);
         } else { g_fail++; printf("  setup failed\n"); }
      }

      // ---- P4: coloured triangle ----
      printf("== P4 render pass: coloured triangle into BGRA8 64x64\n");
      id rt = tex2d(MTLPixelFormatBGRA8Unorm, 64, 64, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_color"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         static const float tri[3 * 8] = {
            -1, -1, 0, 1,   1, 0, 0, 1,     // bottom-left red
             1, -1, 0, 1,   0, 1, 0, 1,     // bottom-right green
            -1,  1, 0, 1,   0, 0, 1, 1 };   // top-left blue
         id vb = [g_dev newBufferWithBytes:tri length:sizeof(tri) options:0];
         if (pso && rt && vb) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            CHECK(run(cb, "triangle"), "render pass did not complete");
            uint8_t px[64 * 64 * 4];
            [rt getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
            unsigned bad = 0, inside = 0, checked = 0;
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
               // pixel centre in NDC (y up, row 0 at the top)
               float nx = (x + 0.5f) / 32.0f - 1.0f, ny = 1.0f - (y + 0.5f) / 32.0f;
               // barycentric weights: red at (-1,-1), green at (1,-1), blue at (-1,1)
               float wg = (nx + 1) / 2, wb = (ny + 1) / 2, wr = 1 - wg - wb;
               uint8_t *p = px + (y * 64 + x) * 4;       // B G R A
               float margin = 0.03f;
               if (wr > margin && wg > margin && wb > margin) {
                  checked++; inside++;
                  float er = wr * 255, eg = wg * 255, eb = wb * 255;
                  if (fabsf(p[2] - er) > 3 || fabsf(p[1] - eg) > 3 || fabsf(p[0] - eb) > 3 || p[3] != 255) { if (bad++ < 3) printf("    (%d,%d) got %u,%u,%u want %.0f,%.0f,%.0f\n", x, y, p[2], p[1], p[0], er, eg, eb); }
               } else if (wr < -margin || wg < -margin || wb < -margin) {
                  checked++;
                  if (p[0] || p[1] || p[2] || p[3] != 255) { if (bad++ < 3) printf("    outside (%d,%d) not the clear colour: %u,%u,%u,%u\n", x, y, p[2], p[1], p[0], p[3]); }
               }
            }
            CHECK(bad == 0 && inside > 1500, "triangle: %u wrong of %u checked pixels (%u inside)", bad, checked, inside);
            printf("  %u of %u checked pixels correct (%u inside the triangle)\n", checked - bad, checked, inside);
         } else { g_fail++; printf("  setup failed\n"); }
      }

      // ---- P5: textured quad ----
      printf("== P5 textured quad (4x4 checker, nearest sampler)\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         static const float quad[6 * 8] = {
            -1, -1, 0, 1, 1,1,1,1,   1, -1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1,
             1, -1, 0, 1, 1,1,1,1,   1,  1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
         sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         id rt2 = tex2d(MTLPixelFormatBGRA8Unorm, 64, 64, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         if (pso && vb && t && smp && rt2) {
            uint8_t tx[4 * 4 * 4];
            for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
               uint8_t *p = tx + (y * 4 + x) * 4;
               p[0] = x * 80; p[1] = y * 80; p[2] = ((x + y) & 1) ? 255 : 0; p[3] = 255;
            }
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:tx bytesPerRow:16];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt2;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setFragmentTexture:t atIndex:0];
            [e setFragmentSamplerState:smp atIndex:0];
            // A retained-reference encoder owns its bound resources before the
            // draw too. Astronomy releases newly loaded textures after binding.
            [pso release]; [vb release]; [t release]; [smp release];
            pso = vb = t = smp = nil;
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            CHECK(run(cb, "textured quad"), "render pass did not complete");
            uint8_t px[64 * 64 * 4];
            [rt2 getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
            unsigned bad = 0;
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
               // uv.y = 1 - (y+.5)/64 (pos.y up), so texel row = 3 - y/16; uv.x = (x+.5)/64 -> texel col x/16
               int tcol = x / 16, trow = 3 - y / 16;
               uint8_t *want = tx + (trow * 4 + tcol) * 4, *p = px + (y * 64 + x) * 4;   // want is RGBA, p is BGRA
               if (p[2] != want[0] || p[1] != want[1] || p[0] != want[2] || p[3] != 255) { if (bad++ < 3) printf("    (%d,%d) got %u,%u,%u want %u,%u,%u\n", x, y, p[2], p[1], p[0], want[0], want[1], want[2]); }
            }
            CHECK(bad == 0, "textured quad: %u of 4096 pixels wrong", bad);
            printf("  %u of 4096 pixels correct\n", 4096 - bad);
         } else { g_fail++; printf("  setup failed (pso=%d vb=%d t=%d smp=%d rt=%d)\n", pso != nil, vb != nil, t != nil, smp != nil, rt2 != nil); }
      }
      // ---- P6: the same quad with a constexpr (inline) sampler ----
      printf("== P6 textured quad with an inline sampler\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex_inline"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         static const float quad[6 * 8] = {
            -1, -1, 0, 1, 1,1,1,1,   1, -1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1,
             1, -1, 0, 1, 1,1,1,1,   1,  1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         id rt3 = tex2d(MTLPixelFormatBGRA8Unorm, 64, 64, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         if (pso && vb && t && rt3) {
            uint8_t tx[4 * 4 * 4];
            for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) { uint8_t *p = tx + (y * 4 + x) * 4; p[0] = x * 80; p[1] = y * 80; p[2] = ((x + y) & 1) ? 255 : 0; p[3] = 255; }
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:tx bytesPerRow:16];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt3;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setFragmentTexture:t atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            CHECK(run(cb, "inline-sampler quad"), "render pass did not complete");
            uint8_t px[64 * 64 * 4];
            [rt3 getBytes:px bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
            unsigned bad = 0;
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) {
               int tcol = x / 16, trow = 3 - y / 16;
               uint8_t *want = tx + (trow * 4 + tcol) * 4, *p = px + (y * 64 + x) * 4;
               if (p[2] != want[0] || p[1] != want[1] || p[0] != want[2] || p[3] != 255) { if (bad++ < 3) printf("    (%d,%d) got %u,%u,%u want %u,%u,%u\n", x, y, p[2], p[1], p[0], want[0], want[1], want[2]); }
            }
            CHECK(bad == 0, "inline-sampler quad: %u of 4096 pixels wrong", bad);
            printf("  %u of 4096 pixels correct\n", 4096 - bad);
         } else { g_fail++; printf("  setup failed\n"); }
      }
      // ---- P7: linear filter, level(0), clamp, constant-buffer offset, into RGBA32Float (compared with a CPU bilinear) ----
      printf("== P7 linear sample + constant buffer offset, RGBA32Float target\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex_linear"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         static const float quad[6 * 8] = {
            -1, -1, 0, 1, 1,1,1,1,   1, -1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1,
             1, -1, 0, 1, 1,1,1,1,   1,  1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         float off[4] = { 0.3f, -0.2f, 0, 0 };
         id ub = [g_dev newBufferWithBytes:off length:16 options:0];
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
         sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         id rt4 = tex2d(MTLPixelFormatRGBA32Float, 32, 32, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         if (pso && vb && ub && t && smp && rt4) {
            uint8_t tx[4 * 4 * 4];
            for (int i = 0; i < 64; i++) tx[i] = (uint8_t)(i * 37 + 11);
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:tx bytesPerRow:16];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt4;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(9, 9, 9, 9);
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setFragmentBuffer:ub offset:0 atIndex:1];
            [e setFragmentTexture:t atIndex:0];
            [e setFragmentSamplerState:smp atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            CHECK(run(cb, "linear quad"), "render pass did not complete");
            float px[32 * 32 * 4];
            [rt4 getBytes:px bytesPerRow:32 * 16 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
            unsigned bad = 0;
            double worst = 0;
            for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
               double uvx = (x + 0.5) / 32.0 + off[0], uvy = 1.0 - (y + 0.5) / 32.0 + off[1];
               double ux = uvx * 4 - 0.5, uy = uvy * 4 - 0.5;
               int ix = (int)floor(ux), iy = (int)floor(uy);
               double fx = ux - ix, fy = uy - iy;
               for (int c = 0; c < 4; c++) {
                  double v = 0;
                  for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) {
                     int cx = ix + dx < 0 ? 0 : ix + dx > 3 ? 3 : ix + dx, cy = iy + dy < 0 ? 0 : iy + dy > 3 ? 3 : iy + dy;
                     v += (dx ? fx : 1 - fx) * (dy ? fy : 1 - fy) * (tx[(cy * 4 + cx) * 4 + c] / 255.0);
                  }
                  double d = fabs(px[(y * 32 + x) * 4 + c] - v);
                  if (d > worst) worst = d;
                  if (d > 0.01) { if (bad++ < 3) printf("    (%d,%d,c%d) got %g want %g\n", x, y, c, px[(y * 32 + x) * 4 + c], v); }
               }
            }
            CHECK(bad == 0, "linear sample: %u of 4096 values off by more than 0.01 (worst %g)", bad, worst);
            printf("  %u of 4096 values within 0.01 of the CPU bilinear (worst error %g)\n", 4096 - bad, worst);
         } else { g_fail++; printf("  setup failed\n"); }
      }
      // ---- P8: texture at slot 3 ----
      printf("== P8 texture at slot 3, nearest, RGBA32Float target\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex3"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         static const float quad[6 * 8] = {
            -1, -1, 0, 1, 1,1,1,1,   1, -1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1,
             1, -1, 0, 1, 1,1,1,1,   1,  1, 0, 1, 1,1,1,1,   -1, 1, 0, 1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         id t = tex2d(MTLPixelFormatRGBA8Unorm, 4, 4, MTLTextureUsageShaderRead);
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         id rt5 = tex2d(MTLPixelFormatRGBA32Float, 32, 32, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         if (pso && vb && t && smp && rt5) {
            uint8_t tx[64];
            for (int i = 0; i < 64; i++) tx[i] = (uint8_t)(i * 37 + 11);
            [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:tx bytesPerRow:16];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt5;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(9, 9, 9, 9);
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            [e setFragmentTexture:t atIndex:3];
            [e setFragmentSamplerState:smp atIndex:0];
            if (getenv("P8_SAMPLERS")) for (int i = 1; i < 4; i++) [e setFragmentSamplerState:smp atIndex:i];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            CHECK(run(cb, "slot-3 quad"), "render pass did not complete");
            float px[32 * 32 * 4];
            [rt5 getBytes:px bytesPerRow:32 * 16 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
            unsigned bad = 0;
            for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
               int tcol = x / 8, trow = 3 - y / 8;
               for (int c = 0; c < 4; c++) if (fabsf(px[(y * 32 + x) * 4 + c] - tx[(trow * 4 + tcol) * 4 + c] / 255.0f) > 1e-3f) bad++;
            }
            CHECK(bad == 0, "slot 3: %u of 4096 values wrong", bad);
            printf("  %u of 4096 values correct\n", 4096 - bad);
         } else { g_fail++; printf("  setup failed (pso=%d)\n", pso != nil); }
      }
      // ---- P9: depth test (Depth32Float, compare Less): the nearer triangle drawn FIRST must win over the farther one drawn second ----
      printf("== P9 depth/stencil state: near red triangle then far green triangle, depth Less\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_color"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         printf("  pipeline: %s\n", pso ? "created" : (err ? [[err localizedDescription] UTF8String] : "nil"));
         MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
         dd.depthCompareFunction = MTLCompareFunctionLess;
         dd.depthWriteEnabled = YES;
         id dss = [g_dev newDepthStencilStateWithDescriptor:dd];
         static const float near_[3 * 8] = { -1, -1, 0.25f, 1, 1, 0, 0, 1,   3, -1, 0.25f, 1, 1, 0, 0, 1,   -1, 3, 0.25f, 1, 1, 0, 0, 1 };
         static const float far_[3 * 8] = { -1, -1, 0.75f, 1, 0, 1, 0, 1,   3, -1, 0.75f, 1, 0, 1, 0, 1,   -1, 3, 0.75f, 1, 0, 1, 0, 1 };
         id vb1 = [g_dev newBufferWithBytes:near_ length:sizeof(near_) options:0], vb2 = [g_dev newBufferWithBytes:far_ length:sizeof(far_) options:0];
         id rt6 = tex2d(MTLPixelFormatBGRA8Unorm, 32, 32, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
         id dt = tex2d(MTLPixelFormatDepth32Float, 32, 32, MTLTextureUsageRenderTarget);
         if (pso && dss && vb1 && vb2 && rt6 && dt) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt6;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.depthAttachment.texture = dt;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.clearDepth = 1.0;
            id cb = [g_queue commandBuffer];
            id e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso];
            [e setDepthStencilState:dss];
            [e setVertexBuffer:vb1 offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e setVertexBuffer:vb2 offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding];
            CHECK(run(cb, "depth test"), "render pass did not complete");
            uint8_t px[32 * 32 * 4];
            [rt6 getBytes:px bytesPerRow:32 * 4 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
            unsigned red = 0, green = 0;
            for (int i = 0; i < 32 * 32; i++) { uint8_t *p = px + i * 4; if (p[2] > 200 && p[1] < 50) red++; else if (p[1] > 200 && p[2] < 50) green++; }
            CHECK(red == 1024 && green == 0, "depth test: %u red, %u green pixels (want 1024 red)", red, green);
            printf("  %u red (near), %u green (far) of 1024\n", red, green);
         } else { g_fail++; printf("  setup failed (pso=%d dss=%d dt=%d)\n", pso != nil, dss != nil, dt != nil); }
      }
      // jasmine P10: attachment feedback after clear and preceding draws, two targets.
      printf("== P10 two-attachment feedback\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_feedback"];
         pd.colorAttachments[0].pixelFormat = pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA32Float;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         CHECK(pso != nil, "feedback pipeline: %s", err.localizedDescription.UTF8String);
         pd.rasterSampleCount = 4;
         NSError *msError = nil;
         id unsupported = [g_dev newRenderPipelineStateWithDescriptor:pd error:&msError];
         CHECK(!unsupported && msError != nil, "multisample feedback must be refused");
         [unsupported release];
         pd.rasterSampleCount = 1;
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_feedback_seed"];
         id seed = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         CHECK(seed != nil, "feedback seed pipeline: %s", err.localizedDescription.UTF8String);
         // First exercise a retained barrier while optional GMEM is armed;
         // then exercise an empty-batch fallback in the same process.
         if (pso && seed) for (int seeded = 1; seeded >= 0; seeded--) {
            static const float quad[6 * 8] = {
               -1,-1,0,1, 1,1,1,1,  1,-1,0,1, 1,1,1,1, -1,1,0,1, 1,1,1,1,
               -1,1,0,1, 1,1,1,1,   1,-1,0,1, 1,1,1,1, 1,1,0,1, 1,1,1,1 };
            id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
            id targets[2];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            for (int a = 0; a < 2; a++) {
               targets[a] = tex2d(MTLPixelFormatRGBA32Float, 37, 19, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
               rp.colorAttachments[a].texture = targets[a];
               rp.colorAttachments[a].loadAction = MTLLoadActionClear;
               rp.colorAttachments[a].clearColor = MTLClearColorMake(10+a,20+a,30+a,1);
               rp.colorAttachments[a].storeAction = MTLStoreActionStore;
            }
            id cb = [g_queue commandBuffer], e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setVertexBuffer:vb offset:0 atIndex:0];
            if (seeded) {
               [e setRenderPipelineState:seed];
               [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
            [e setRenderPipelineState:pso];
            for (int i = 0; i < 3; i++) [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [e endEncoding];
            if (seeded) {
               // A later clear must stay ordered after the fetching draws.
               // Load color0, clear color1, then fetch into half the target.
               rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
               rp.colorAttachments[1].clearColor = MTLClearColorMake(0,0,0,1);
               e = [cb renderCommandEncoderWithDescriptor:rp];
               [e setRenderPipelineState:pso]; [e setVertexBuffer:vb offset:0 atIndex:0];
               [e setScissorRect:(MTLScissorRect){0,0,18,19}];
               [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
               [e endEncoding];
            }
            CHECK(run(cb, "feedback"), "feedback did not complete");
            unsigned bad = 0;
            for (int a = 0; a < 2; a++) {
               float px[37*19*4];
               [targets[a] getBytes:px bytesPerRow:37*16 fromRegion:MTLRegionMake2D(0,0,37,19) mipmapLevel:0];
               float want[4] = { 10+a+3*(a?3:1),20+a+6,30+a+3*(a?1:3),1 };
               for (unsigned i = 0; i < 37*19*4; i++) {
                  unsigned c = i%4; BOOL left = (i/4)%37 < 18;
                  float expected = want[c];
                  if (seeded && c < 3) {
                     if (a) expected = left ? (float)(3-c) : 0;
                     else if (left) expected += c+1;
                  }
                  if (px[i] != expected) {
                     if (bad < 3) printf("    feedback a%d i%u got %g want %g\n",a,i,px[i],expected); bad++;
                  }
               }
            }
            CHECK(!bad, "feedback %u wrong values", bad);
            printf("  feedback: %u/5624 exact values\n",5624-bad);
            [targets[0] release]; [targets[1] release]; [vb release];
         }
         [seed release]; [pso release]; [pd release];
      }
      // jasmine P11: repeated CPU writes -> GPU reads, GPU writes -> direct CPU reads.
      printf("== P11 imported IOSurface visibility\n");
      {
         NSDictionary *props = @{ (id)kIOSurfaceWidth:@37, (id)kIOSurfaceHeight:@19,
            (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@256,
            (id)kIOSurfacePixelFormat:@(0x42475241u) };
         IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)props);
         CHECK(surf != NULL, "IOSurfaceCreate");
         id pso = compute_pso(klib, "bg_tex_read");
         id out = [g_dev newBufferWithLength:37*19*16 options:0];
         MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:37 height:19 mipmapped:NO];
         td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
         td.storageMode = MTLStorageModeShared;
         unsigned bad = 0, rounds = 0;
         if (surf && pso && out) for (unsigned r = 0; r < 12; r++) {
            IOSurfaceLock(surf, 0, NULL);
            uint8_t *base = IOSurfaceGetBaseAddress(surf); size_t pitch = IOSurfaceGetBytesPerRow(surf);
            for (unsigned y=0;y<19;y++) for(unsigned x=0;x<37;x++) {
               uint8_t *p=base+y*pitch+x*4; p[0]=(x+r*17)%256; p[1]=(y+r*23)%256; p[2]=(x+y+r*31)%256; p[3]=255;
            }
            IOSurfaceUnlock(surf, 0, NULL);
            id t = [g_dev newTextureWithDescriptor:td iosurface:(id)surf plane:0];
            if (!t) { bad++; break; }
            id cb=[g_queue commandBuffer], e=[cb computeCommandEncoder];
            [e setComputePipelineState:pso]; [e setTexture:t atIndex:0]; [e setBuffer:out offset:0 atIndex:0];
            [e dispatchThreads:MTLSizeMake(37,19,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            [e endEncoding]; if (!run(cb,"surface read")) { bad++; break; }
            float *got=[out contents];
            for(unsigned y=0;y<19;y++) for(unsigned x=0;x<37;x++) {
               unsigned v[4]={(x+y+r*31)%256,(y+r*23)%256,(x+r*17)%256,255};
               for(unsigned c=0;c<4;c++) if(fabsf(got[(y*37+x)*4+c]-v[c]/255.0f)>0.00001f) bad++;
            }
            MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture=t; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
            rp.colorAttachments[0].clearColor=MTLClearColorMake((r+1)/16.0,0.5,0.25,1);
            rp.colorAttachments[0].storeAction=MTLStoreActionStore;
            cb=[g_queue commandBuffer]; e=[cb renderCommandEncoderWithDescriptor:rp]; [e endEncoding];
            if (!run(cb,"surface clear")) { bad++; break; }
            IOSurfaceLock(surf,kIOSurfaceLockReadOnly,NULL);
            base=IOSurfaceGetBaseAddress(surf);
            for(unsigned y=0;y<19;y++) for(unsigned x=0;x<37;x++) {
               uint8_t *p=base+y*pitch+x*4;
               if(abs(p[2]-(int)lroundf((r+1)*255/16.0f))>1 || abs(p[1]-128)>1 || abs(p[0]-64)>1 || p[3]!=255) bad++;
            }
            IOSurfaceUnlock(surf,kIOSurfaceLockReadOnly,NULL);
            [t release]; rounds++;
         }
         CHECK(rounds==12 && !bad,"IOSurface: %u rounds, %u wrong",rounds,bad);
         printf("  IOSurface: %u rounds, %u wrong\n",rounds,bad);
         if(surf) CFRelease(surf);
      }
      // jasmine P13: a GPU blit from a private texture into an imported IOSurface (the compositor's shadow copy-back),
      // at a swap-surface-like size and a 64-byte-multiple pitch that is not a power of two.
      printf("== P13 GPU blit into an imported IOSurface\n");
      {
         const unsigned W = 200, H = 64;
         NSDictionary *props = @{ (id)kIOSurfaceWidth:@(W), (id)kIOSurfaceHeight:@(H),
            (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@832,
            (id)kIOSurfacePixelFormat:@(0x42475241u) };
         IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)props);
         MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
         td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
         id src = [g_dev newTextureWithDescriptor:td];
         td.storageMode = MTLStorageModeShared;
         id dst = surf ? [g_dev newTextureWithDescriptor:td iosurface:(id)surf plane:0] : nil;
         unsigned bad = 0;
         if (src && dst) {
            MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture=src; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
            rp.colorAttachments[0].clearColor=MTLClearColorMake(0.25,0.5,0.75,1);
            rp.colorAttachments[0].storeAction=MTLStoreActionStore;
            id cb=[g_queue commandBuffer], e=[cb renderCommandEncoderWithDescriptor:rp]; [e endEncoding];
            id b=[cb blitCommandEncoder];
            [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1)
                     toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            [b endEncoding];
            if (!run(cb,"blit into surface")) bad++;
            IOSurfaceLock(surf,kIOSurfaceLockReadOnly,NULL);
            uint8_t *base=IOSurfaceGetBaseAddress(surf); size_t pitch=IOSurfaceGetBytesPerRow(surf);
            for(unsigned y=0;y<H;y++) for(unsigned x=0;x<W;x++) {
               uint8_t *p=base+y*pitch+x*4;
               if(abs(p[0]-191)>1 || abs(p[1]-128)>1 || abs(p[2]-64)>1 || p[3]!=255) bad++;
            }
            printf("  first texel b=%u g=%u r=%u a=%u\n", base[0], base[1], base[2], base[3]);
            IOSurfaceUnlock(surf,kIOSurfaceLockReadOnly,NULL);
         } else bad++;
         CHECK(!bad,"blit into IOSurface: %u wrong",bad);
         printf("  blit into IOSurface: %u wrong\n",bad);
         [src release]; [dst release];
         if(surf) CFRelease(surf);
      }
      // jasmine P12: a read-only vertex buffer beyond UBO capacity fails explicitly.
      printf("== P12 oversized vertex device buffer refusal\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_color"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         id vb = [g_dev newBufferWithLength:1<<20 options:0];
         id rt = tex2d(MTLPixelFormatBGRA8Unorm, 16, 16, MTLTextureUsageRenderTarget);
         if (pso && vb && rt) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id cb=[g_queue commandBuffer], e=[cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso]; [e setVertexBuffer:vb offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
            [cb commit]; [cb waitUntilCompleted];
            CHECK([cb status]==MTLCommandBufferStatusError && [cb error]!=nil,"oversized VS buffer must fail");
            printf("  oversized vertex buffer: status=%ld error=%s\n",(long)[cb status],[[[cb error] localizedDescription] UTF8String]);
         } else { CHECK(NO,"oversized VS refusal setup"); }
      }
      // P14: ASTC blocks, page-rounded allocation, partial blocks, all mip levels,
      // and caller mutations between commits. The old length/height pitch fails.
      printf("== P14 packed ASTC no-copy images\n");
      {
         id pso = compute_pso(klib, "bg_tex_sample_lod");
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
         sd.mipFilter = MTLSamplerMipFilterNearest;
         id sampler = [g_dev newSamplerStateWithDescriptor:sd];
         const unsigned dims[][3] = { {144,144,1}, {224,487,1}, {828,9,1}, {13,9,4} };
         unsigned bad = 0, values = 0;
         for (unsigned test = 0; test < sizeof(dims)/sizeof(dims[0]); test++) {
            unsigned W=dims[test][0], H=dims[test][1], levels=dims[test][2];
            size_t used=0;
            for (unsigned l=0;l<levels;l++) {
               unsigned w=MAX(1,W>>l),h=MAX(1,H>>l);
               used += ((w+3)/4)*((h+3)/4)*16;
            }
            size_t length=(used+16383)&~(size_t)16383;
            uint8_t *mem=malloc(length);
            memset(mem,0xa5,length);
            MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_4x4_LDR width:W height:H mipmapped:NO];
            td.mipmapLevelCount=levels; td.usage=MTLTextureUsageShaderRead; td.storageMode=MTLStorageModeShared;
            id t=nil;
            for (unsigned round=0;round<2;round++) {
               size_t offset=0;
               for (unsigned l=0;l<levels;l++) {
                  unsigned w=MAX(1,W>>l),h=MAX(1,H>>l);
                  for(unsigned y=0;y<(h+3)/4;y++) for(unsigned x=0;x<(w+3)/4;x++) {
                     // ASTC LDR void-extent block: exact constant RGBA per 4x4 block.
                     uint16_t block[8]={0xfdfc,0xffff,0xffff,0xffff,
                        ((x+y+round+l)&1)?0xffff:0, (l&1)?0xffff:0, round?0xffff:0, 0xffff};
                     memcpy(mem+offset,block,16); offset+=16;
                  }
               }
               if (!round) {
                  t=[g_dev newTextureWithBytesNoCopy:mem length:length descriptor:td deallocator:nil];
                  if(!t || !pso || !sampler) { bad++; break; }
                  id shortTex=[g_dev newTextureWithBytesNoCopy:mem length:used-1 descriptor:td deallocator:nil];
                  if(shortTex) { bad++; [shortTex release]; }
               }
               for (unsigned l=0;l<levels;l++) {
                  unsigned w=MAX(1,W>>l),h=MAX(1,H>>l);
                  id out=[g_dev newBufferWithLength:(size_t)w*h*16 options:0];
                  memset([out contents],0xa5,(size_t)w*h*16);
                  id cb=[g_queue commandBuffer],e=[cb computeCommandEncoder];
                  [e setComputePipelineState:pso]; [e setTexture:t atIndex:0]; [e setSamplerState:sampler atIndex:0];
                  [e setBuffer:out offset:0 atIndex:0]; [e setBytes:&l length:sizeof(l) atIndex:1];
                  [e dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
                  [e endEncoding]; if(!run(cb,"ASTC no-copy sample")) bad++;
                  float *px=[out contents];
                  for(unsigned y=0;y<h;y++) for(unsigned x=0;x<w;x++) {
                     float want[4]={((x/4+y/4+round+l)&1)?1:0,(l&1)?1:0,round?1:0,1};
                     for(unsigned c=0;c<4;c++) {
                        float got=px[(y*w+x)*4+c];
                        if(!isfinite(got) || fabsf(got-want[c])>0.00001f) bad++;
                        values++;
                     }
                  }
                  [out release];
               }
            }
            [t release]; free(mem);
         }
         CHECK(!bad,"ASTC no-copy: %u wrong / %u values",bad,values);
         printf("  ASTC no-copy: %u wrong / %u values (including mip chain and CPU refresh)\n",bad,values);
         [sampler release]; [sd release];
      }
      // P15: a derivative-only shader needs helper lanes at the shared edge
      // of these triangles. Compare the entire circle, including that edge.
      printf("== P15 derivative coverage across primitive edges\n");
      {
         enum { N = 128 };
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_quad_helpers"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         NSError *err = nil;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:&err];
         const float quad[6 * 8] = {
            -1,-1,0,1, 1,1,1,1,  1,-1,0,1, 1,1,1,1, -1,1,0,1, 1,1,1,1,
             1,-1,0,1, 1,1,1,1,  1, 1,0,1, 1,1,1,1, -1,1,0,1, 1,1,1,1 };
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         id rt = tex2d(MTLPixelFormatBGRA8Unorm, N, N, MTLTextureUsageRenderTarget);
         unsigned bad = 0, edge = 0;
         if (pso && vb && rt) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id cb = [g_queue commandBuffer], e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso]; [e setVertexBuffer:vb offset:0 atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [e endEncoding];
            if (!run(cb, "derivative circle")) bad++;
            uint8_t px[N * N * 4];
            [rt getBytes:px bytesPerRow:N * 4 fromRegion:MTLRegionMake2D(0, 0, N, N) mipmapLevel:0];
            for (int y = 0; y < N; y++) for (int x = 0; x < N; x++) {
               float u = (x + 0.5f - N / 2) / (N / 2), v = (y + 0.5f - N / 2) / (N / 2);
               // Exact coarse differences of u*u + v*v across a 2x2 quad.
               float dx = 2.0f * ((x & ~1) + 1 - N / 2) / ((N / 2) * (N / 2));
               float dy = 2.0f * ((y & ~1) + 1 - N / 2) / ((N / 2) * (N / 2));
               float coverage = (0.5625f - u*u - v*v) / fmaxf(fabsf(dx) + fabsf(dy), 0.0001f) + 0.5f;
               int want = (int)lrintf(fminf(1, fmaxf(0, coverage)) * 255);
               if (want > 0 && want < 255) edge++;
               for (unsigned c = 0; c < 4; c++) if (abs(px[(y*N+x)*4+c] - want) > 3) {
                  if (bad < 4) printf("  helper (%d,%d) channel %u: %u expected %d\n", x, y, c, px[(y*N+x)*4+c], want);
                  bad++; break;
               }
            }
         } else { bad++; printf("  derivative setup: %s\n", err ? [[err localizedDescription] UTF8String] : "nil"); }
         CHECK(!bad && edge > 100, "derivative coverage: %u wrong, %u edge pixels", bad, edge);
         printf("  derivative coverage: %u wrong, %u edge pixels\n", bad, edge);
         [pso release]; [vb release]; [rt release]; [pd release];
      }
      // P16: no-copy exact comparison must retain mutable-memory semantics.
      // Exercise render reuse (two draws), mutations, and both CPU/GPU blits.
      printf("== P16 mutable no-copy refresh and write invalidation\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         id pso = [g_dev newRenderPipelineStateWithDescriptor:pd error:NULL];
         const float quad[] = {-1,-1,0,1,1,1,1,1, 1,-1,0,1,1,1,1,1, -1,1,0,1,1,1,1,1,
                                1,-1,0,1,1,1,1,1, 1,1,0,1,1,1,1,1, -1,1,0,1,1,1,1,1};
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
         sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
         id smp = [g_dev newSamplerStateWithDescriptor:sd];
         unsigned bad = 0, checked = 0;
         for (unsigned compressed=0; compressed<2; compressed++) {
            NSUInteger fmt = compressed ? MTLPixelFormatASTC_4x4_LDR : MTLPixelFormatRGBA8Unorm;
            size_t used = compressed ? 16 : 64, row = 16;
            uint8_t mem[4096], red[64]; memset(mem,0xa5,sizeof(mem));
            for(unsigned i=0;i<16;i++) { red[i*4]=255; red[i*4+1]=red[i*4+2]=0; red[i*4+3]=255; }
            uint16_t block[8]={0xfdfc,0xffff,0xffff,0xffff,0xffff,0,0,0xffff};
            if(compressed) memcpy(red,block,16);
            memcpy(mem,red,used);
            MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:4 height:4 mipmapped:NO];
            td.usage=MTLTextureUsageShaderRead; td.storageMode=MTLStorageModeShared;
            id t=[g_dev newTextureWithBytesNoCopy:mem length:sizeof(mem) descriptor:td deallocator:nil];
            id src=[g_dev newTextureWithDescriptor:td];
            [src replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:red bytesPerRow:row];
            id buf=[g_dev newBufferWithBytes:red length:used options:0];
            id target=tex2d(MTLPixelFormatBGRA8Unorm,8,8,MTLTextureUsageRenderTarget);
            if(!t || !src || !buf || !target || !pso || !vb || !smp) { bad++; continue; }
            for(unsigned round=0;round<8;round++) { @autoreleasepool {
               printf("  no-copy format %lu round %u\n", (unsigned long)fmt, round);
               // Mutate after creation, then between commits. Padding is irrelevant.
               if(round==0 || round==2) {
                  if(compressed) {
                     block[4]=0;block[5]=round==2?0xffff:0;block[6]=round==0?0xffff:0;
                     memcpy(mem,block,16);
                  } else for(unsigned i=0;i<16;i++) { mem[i*4]=0;mem[i*4+1]=round==2?255:0;mem[i*4+2]=round==0?255:0;mem[i*4+3]=255; }
               }
               mem[used]++; // page padding must not affect content comparison
               if(round==7) [t replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:red bytesPerRow:row];
               id cb=[g_queue commandBuffer];
               if(round==3 || round==5) {
                  id blit=[cb blitCommandEncoder];
                  if(round==3) [blit copyFromBuffer:buf sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:used sourceSize:MTLSizeMake(4,4,1)
                                          toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
                  else [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1)
                                   toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
                  [blit endEncoding];
               }
               MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
               rp.colorAttachments[0].texture=target;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
               id e=[cb renderCommandEncoderWithDescriptor:rp];
               [e setRenderPipelineState:pso];[e setVertexBuffer:vb offset:0 atIndex:0];[e setFragmentTexture:t atIndex:0];[e setFragmentSamplerState:smp atIndex:0];
               for(unsigned draw=0;draw<2;draw++) [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
               [e endEncoding]; if(!run(cb,"no-copy lifecycle"))bad++;
               uint8_t px[8*8*4];[target getBytes:px bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
               // CPU blits invalidate the epoch, so raw caller memory wins on the
               // following draw. GPU copies keep the epoch and remain visible there.
               unsigned want = round==5 ? 2 : round<2 ? 0 : 1;
               for(unsigned i=0;i<64;i++) for(unsigned c=0;c<4;c++) { if(px[i*4+c] != ((c==want || c==3)?255:0))bad++;checked++; }
            }} // release each completed command buffer: Metal queues bound outstanding objects
            [t release];[src release];[buf release];[target release];
         }
         CHECK(!bad,"no-copy lifecycle: %u wrong / %u values",bad,checked);
         printf("  no-copy lifecycle: %u wrong / %u values\n",bad,checked);
         [smp release];[sd release];[vb release];[pso release];[pd release];
      }
      // P17: throttling diagnostics must not change texture-creation results.
      printf("== P17 repeated unsupported texture refusals\n");
      {
         MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)500 width:4 height:4 mipmapped:NO];
         td.usage = MTLTextureUsageShaderRead;
         unsigned accepted = 0;
         for (unsigned i = 0; i < 1000; ++i) {
            id t = [g_dev newTextureWithDescriptor:td];
            if (t) { ++accepted; [t release]; }
         }
         td.pixelFormat = (MTLPixelFormat)501; // different reason must remain visible
         id other = [g_dev newTextureWithDescriptor:td];
         if (other) { ++accepted; [other release]; }
         td.pixelFormat = MTLPixelFormatRGBA8Unorm;
         id good = [g_dev newTextureWithDescriptor:td];
         CHECK(!accepted && good, "unsupported formats still return nil; supported creation survives: %u accepted", accepted);
         [good release];
      }
      // P18: independently executable batches must restore all draw state.
      // Switch targets and pipelines, sample a prior target, retain untouched
      // pixels, then reuse bindings in a new command buffer. Recreate resources.
      printf("== P18 batch state across target switches and recreation\n");
      {
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_color"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         id color = [g_dev newRenderPipelineStateWithDescriptor:pd error:NULL];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex_inline"];
         id sample = [g_dev newRenderPipelineStateWithDescriptor:pd error:NULL];
         unsigned bad = 0, checked = 0;
         for (unsigned round = 0; round < 6; round++) { @autoreleasepool {
            unsigned n = round & 1 ? 12 : 8;
            float quad[] = {-1,-1,0,1,1,0,0,1, 1,-1,0,1,1,0,0,1, -1,1,0,1,1,0,0,1,
                             1,-1,0,1,1,0,0,1, 1,1,0,1,1,0,0,1, -1,1,0,1,1,0,0,1};
            id vb[2];
            vb[0] = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
            for (unsigned v = 0; v < 6; v++) { quad[v*8+4] = 0; quad[v*8+5] = 1; }
            vb[1] = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
            id a = tex2d(MTLPixelFormatBGRA8Unorm, n, n, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
            id b = tex2d(MTLPixelFormatBGRA8Unorm, n, n, MTLTextureUsageRenderTarget);
            if (!color || !sample || !vb[0] || !vb[1] || !a || !b) bad++;
            else for (unsigned commit = 0; commit < 2; commit++) { @autoreleasepool {
               id cb = [g_queue commandBuffer];
               for (unsigned pass = 0; pass < 4; pass++) {
                  MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                  rp.colorAttachments[0].texture = pass & 1 ? b : a;
                  rp.colorAttachments[0].loadAction = pass == 2 ? MTLLoadActionLoad : MTLLoadActionClear;
                  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                  id e = [cb renderCommandEncoderWithDescriptor:rp];
                  [e setRenderPipelineState:pass & 1 ? sample : color];
                  [e setVertexBuffer:vb[pass == 2 ? 1-commit : commit] offset:0 atIndex:0];
                  if (pass & 1) [e setFragmentTexture:a atIndex:0];
                  if (pass == 2) [e setScissorRect:(MTLScissorRect){0, 0, n/2, n}];
                  for (unsigned draw = 0; draw < 2; draw++)
                     [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                  [e endEncoding];
               }
               if (!run(cb, "batch state transitions")) bad++;
               uint8_t px[12*12*4];
               [b getBytes:px bytesPerRow:n*4 fromRegion:MTLRegionMake2D(0,0,n,n) mipmapLevel:0];
               for (unsigned y=0; y<n; y++) for (unsigned x=0; x<n; x++) {
                  unsigned green = x < n/2 ? 1-commit : commit;
                  for (unsigned c=0; c<4; c++) {
                     unsigned want = (c == 3 || c == (green ? 1 : 2)) ? 255 : 0;
                     if (px[(y*n+x)*4+c] != want) bad++;
                     checked++;
                  }
               }
            }}
            [a release]; [b release]; [vb[0] release]; [vb[1] release];
         }}
         CHECK(!bad, "batch state transitions: %u wrong / %u values", bad, checked);
         printf("  batch state transitions: %u wrong / %u values\n", bad, checked);
         [color release]; [sample release]; [pd release];
      }
      // P19: a long RAW chain crosses deferred-group capacity boundaries.
      // Every intermediate must remain alive and visible to its next consumer;
      // reusing the chain in a second commit also checks fence/drain ordering.
      printf("== P19 bounded submission dependency chain\n");
      {
         enum { COUNT = 80, N = 8 };
         MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction = [rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction = [rlib newFunctionWithName:@"bg_fs_tex_inline"];
         pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
         id sample = [g_dev newRenderPipelineStateWithDescriptor:pd error:NULL];
         float quad[] = {-1,-1,0,1,1,0,0,1, 1,-1,0,1,1,0,0,1, -1,1,0,1,1,0,0,1,
                          1,-1,0,1,1,0,0,1, 1,1,0,1,1,0,0,1, -1,1,0,1,1,0,0,1};
         id vb = [g_dev newBufferWithBytes:quad length:sizeof(quad) options:0];
         id targets[COUNT] = {nil};
         unsigned bad = 0, checked = 0;
         BOOL ready = sample && vb;
         for (unsigned i=0; i<COUNT; i++) {
            targets[i] = tex2d(MTLPixelFormatBGRA8Unorm, N, N,
                              MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
            ready = ready && targets[i];
         }
         if (!ready) bad++;
         else for (unsigned commit=0; commit<2; commit++) { @autoreleasepool {
            id cb = [g_queue commandBuffer];
            for (unsigned i=0; i<COUNT; i++) {
               MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
               rp.colorAttachments[0].texture = targets[i];
               rp.colorAttachments[0].loadAction = MTLLoadActionClear;
               rp.colorAttachments[0].storeAction = MTLStoreActionStore;
               rp.colorAttachments[0].clearColor = i ? MTLClearColorMake(0,0,1,1) :
                  commit ? MTLClearColorMake(0,1,0,1) : MTLClearColorMake(1,0,0,1);
               id e = [cb renderCommandEncoderWithDescriptor:rp];
               if (i) {
                  [e setRenderPipelineState:sample];
                  [e setVertexBuffer:vb offset:0 atIndex:0];
                  [e setFragmentTexture:targets[i-1] atIndex:0];
                  [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
               }
               [e endEncoding];
            }
            if (!run(cb, "submission chain")) bad++;
            for (unsigned i=0; i<COUNT; i++) {
               uint8_t px[N*N*4];
               [targets[i] getBytes:px bytesPerRow:N*4 fromRegion:MTLRegionMake2D(0,0,N,N) mipmapLevel:0];
               for (unsigned j=0; j<N*N*4; j++) {
                  unsigned c=j%4, want=(c==3 || c==(commit ? 1 : 2)) ? 255 : 0;
                  if (px[j]!=want) bad++;
                  checked++;
               }
            }
         }}
         CHECK(!bad, "submission chain: %u wrong / %u values", bad, checked);
         printf("  submission chain: %u wrong / %u values\n", bad, checked);
         for (unsigned i=0; i<COUNT; i++) [targets[i] release];
         [vb release]; [sample release]; [pd release];
      }
      // P20: enqueue without draining between CBs; worker/context ownership,
      // copied handler lifetimes and completion FIFO must survive autorelease.
      printf("== P20 queued replay and callback order\n");
      {
         enum { COUNT=32, N=8 };
         id target=tex2d(MTLPixelFormatBGRA8Unorm,N,N,MTLTextureUsageRenderTarget);
         MTLRenderPipelineDescriptor *pd=[[MTLRenderPipelineDescriptor alloc] init];
         pd.vertexFunction=[rlib newFunctionWithName:@"bg_vs"];
         pd.fragmentFunction=[rlib newFunctionWithName:@"bg_fs_color"];
         pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
         id pso=[g_dev newRenderPipelineStateWithDescriptor:pd error:NULL];
         id oversized=[g_dev newBufferWithLength:1<<20 options:0];
         __block unsigned scheduled=0, completed=0, badScheduled=0, badCompleted=0;
         id last=nil;
         for (unsigned i=0;i<COUNT;i++) { @autoreleasepool {
            MTLRenderPassDescriptor *d=[MTLRenderPassDescriptor renderPassDescriptor];
            d.colorAttachments[0].texture=target;
            d.colorAttachments[0].loadAction=MTLLoadActionClear;
            d.colorAttachments[0].storeAction=MTLStoreActionStore;
            d.colorAttachments[0].clearColor=MTLClearColorMake(i==COUNT-1 ? 1 : 0,0,1,1);
            id cb=[g_queue commandBuffer];
            id encoder=[cb renderCommandEncoderWithDescriptor:d];
            if (i==COUNT/2) {
               // An error after the clear must drain that clear and complete
               // in FIFO order, rather than overtaking earlier queued CBs.
               [encoder setRenderPipelineState:pso];
               [encoder setVertexBuffer:oversized offset:0 atIndex:0];
               [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
            [encoder endEncoding];
            [cb addScheduledHandler:^(id b) { if (scheduled++ != i || [b status]<3) badScheduled++; }];
            [cb addCompletedHandler:^(id b) { if (completed++ != i || [b status]!=(i==COUNT/2 ? 5 : 4)) badCompleted++; }];
            if (i==COUNT-1) last=[cb retain];
            [cb commit];
         }}
         [last waitUntilCompleted];
         uint8_t px[N*N*4];
         [target getBytes:px bytesPerRow:N*4 fromRegion:MTLRegionMake2D(0,0,N,N) mipmapLevel:0];
         unsigned bad=0;
         for (unsigned j=0;j<sizeof(px);j++) if (px[j] != (j%4==1 ? 0 : 255)) bad++;
         CHECK(scheduled==COUNT && completed==COUNT && !badScheduled && !badCompleted && !bad,
               "queued replay: scheduled/completed %u/%u, order/status %u/%u, pixel errors %u",
               scheduled,completed,badScheduled,badCompleted,bad);
         printf("  queued replay: %u/%u callbacks, %u/%u order/status errors, %u wrong values\n",
                scheduled,completed,badScheduled,badCompleted,bad);
         [last release]; [target release]; [oversized release]; [pso release]; [pd release];
      }
      printf("== result: %d checks passed, %d failed\n", g_pass, g_fail);
      return g_fail ? 1 : 0;
   }
}
