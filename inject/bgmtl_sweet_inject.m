// SPDX-License-Identifier: MIT
// jasmine: process-local registration, enabled through sweetenv or exec env.
// Registration requires both an exact process name and BGMTL_ENABLE=1.
// Wallpaper renderers are tested through temporary sweetenv boot entries.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern id bgmtl_create_device(void);

// Keep in sync with the kernel's sweetenv=@wallpaper group (j0121). Exact
// executable names only: neither xpcproxy nor unrelated apps get a device.
// PosterBoard (the poster host) is not a renderer and stays out (j0122 notes).
static BOOL
wallpaper_process(const char *name)
{
   // PridePosterExtension stays out too: its MPS work hung the GPU on pool1 (2026-11-01 03:25), the kernel
   // group still names it, so it gets the environment but no device until that hang is understood.
   static const char *const names[] = {
      "AegirPoster", "CollectionsPoster", "GradientPosterExtension",
      "LegacyPoster", "PhotosPosterProvider",
      "UnityPosterExtension", "EmojiPosterExtension", "ExtragalacticPoster"
   };
   for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++)
      if (!strcmp(name, names[i])) return YES;
   return NO;
}

// Astronomy requests an XR10 drawable unconditionally, even when the device
// correctly reports no XR support. For the scoped SDR experiment, change the
// layer's actual format before its setter validates it. Pipeline builders then
// query that same supported format; the device does not advertise fake XR support.
static void (*poster_set_format)(id, SEL, NSUInteger);
static void (*poster_texture_format)(id, SEL, NSUInteger);
static void (*poster_attachment_format)(id, SEL, NSUInteger);
static NSUInteger
poster_sdr_format(NSUInteger format)
{
   return format >= 550 && format <= 555 ?
      ((format & 1) ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm) : format;
}
static void
poster_set_sdr_format(id layer, SEL sel, NSUInteger format)
{
   poster_set_format(layer, sel, poster_sdr_format(format));
}
static void poster_set_sdr_texture(id d, SEL sel, NSUInteger format)
{ poster_texture_format(d, sel, poster_sdr_format(format)); }
static void poster_set_sdr_attachment(id d, SEL sel, NSUInteger format)
{ poster_attachment_format(d, sel, poster_sdr_format(format)); }

static void
poster_enable_sdr(void)
{
   const char *sdr = getenv("BGMTL_POSTER_SDR");
   if (!sdr || strcmp(sdr, "1")) return;
   Class cls = NSClassFromString(@"CAMetalLayer");
   Method method = cls ? class_getInstanceMethod(cls, sel_getUid("setPixelFormat:")) : NULL;
   MTLTextureDescriptor *texture = [[MTLTextureDescriptor alloc] init];
   MTLRenderPipelineDescriptor *pipeline = [[MTLRenderPipelineDescriptor alloc] init];
   Method tex_method = class_getInstanceMethod(object_getClass(texture), sel_getUid("setPixelFormat:"));
   Method att_method = class_getInstanceMethod(object_getClass(pipeline.colorAttachments[0]), sel_getUid("setPixelFormat:"));
   [texture release]; [pipeline release];
   if (!method || !tex_method || !att_method) { NSLog(@"BGMTL wallpaper SDR: format setter missing"); return; }
   poster_set_format = (void (*)(id, SEL, NSUInteger))method_setImplementation(method, (IMP)poster_set_sdr_format);
   // NanoUniverse also hard-codes XR in intermediate textures and PSOs instead of
   // querying the layer. Keep the actual attachment and pipeline formats equal.
   poster_texture_format = (void (*)(id, SEL, NSUInteger))method_setImplementation(tex_method, (IMP)poster_set_sdr_texture);
   poster_attachment_format = (void (*)(id, SEL, NSUInteger))method_setImplementation(att_method, (IMP)poster_set_sdr_attachment);
   NSLog(@"BGMTL wallpaper SDR: layer, texture and pipeline format fallback enabled");
}

// Keep unknown selectors and backend failures visible in the probe's capture.
void bgmtl_note_unimplemented(const char *sel)
{
   fprintf(stderr, "BGMTL UNIMPLEMENTED: %s\n", sel);
   if (wallpaper_process(getprogname())) NSLog(@"BGMTL UNIMPLEMENTED: %s", sel);
}
// The unified log shows the failure text as <private>: wallpaper processes also append it, and
// the runtime's notes, to a file (the first 64 per process) so the reason can be read back.
static void
poster_note_file(const char *kind, const char *text)
{
   static int told;
   if (!wallpaper_process(getprogname()) || told++ >= 64) return;
   FILE *f = fopen("/private/var/tmp/bgmtl-poster-failures.txt", "a");
   if (!f) return;
   fprintf(f, "%s[%d] %s: %s\n", getprogname(), getpid(), kind, text ? text : "?");
   fclose(f);
}
void bgmtl_note_failure(const char *why)
{
   fprintf(stderr, "BGMTL command buffer failure: %s\n", why ? why : "?");
   if (wallpaper_process(getprogname())) NSLog(@"BGMTL command buffer failure: %s", why ? why : "?");
   poster_note_file("failure", why);
}
void bgmtl_note_line(const char *line)
{ fprintf(stderr, "BGMTL: %s\n", line); poster_note_file("note", line); }

__attribute__((constructor)) static void
bgmtl_sweet_init(void)
{
   const char *enable = getenv("BGMTL_ENABLE");
   const char *name = getprogname();
   BOOL poster = wallpaper_process(name);
   if (!enable || strcmp(enable, "1") ||
       (strcmp(name, "bgmtl_registered_probe") && strcmp(name, "backboardd") &&
        !poster)) return;
   fprintf(stderr, "BGMTL registration: enabled in %s\n", name);
   // The compositor's paths in libbgmtl (render tickets, odd-pitch sampled surfaces, BGR5A1): backboardd always wants them.
   if (!strcmp(name, "backboardd")) setenv("BGMTL_BB", "1", 0);
   // A/B switches without a new boot image: KEY=VALUE lines (FD_MESA_DEBUG=inorder, BGMTL_SHADOW=0, ...), set before
   // the device and its Mesa screen exist. The boot command line has no room left for them.
   const char *env_path = poster ?
      "/private/var/tmp/bgmtl-poster.env" : "/private/var/tmp/bgmtl-bb.env";
   FILE *ab = fopen(env_path, "r");
   if (ab) {
      char line[256];
      while (fgets(line, sizeof(line), ab)) {
         line[strcspn(line, "\r\n")] = 0;
         char *eq = strchr(line, '=');
         if (!eq || eq == line) continue;
         *eq = 0;
         setenv(line, eq + 1, 1);
         fprintf(stderr, "BGMTL registration: %s=%s (%s)\n", line, eq + 1, env_path);
      }
      fclose(ab);
   }
   @autoreleasepool {
      void (*add)(id) = (void (*)(id))dlsym(RTLD_DEFAULT, "MTLAddDevice");
      if (!add) { fprintf(stderr, "BGMTL registration: MTLAddDevice missing\n"); return; }
      // iOS 16 has no MTLCopyAllDevices. Initialise Metal's device array first.
      id before = MTLCreateSystemDefaultDevice();
      if (before) {
         fprintf(stderr, "BGMTL registration: existing device; leaving it alone\n");
         [before release];
         return;
      }
      // SweetGPU has no Bergamota GPU-state query. Screen creation opens the
      // actual user client and is the availability check; never claim ready.
      id dev = bgmtl_create_device();
      if (!dev) { fprintf(stderr, "BGMTL registration: device creation failed\n"); return; }
      add(dev);
      id selected = MTLCreateSystemDefaultDevice();
      fprintf(stderr, "BGMTL registration: selected=%s same=%d\n",
              selected ? object_getClassName(selected) : "nil", selected == dev);
      if (poster) NSLog(@"BGMTL wallpaper registration: %s selected=%s same=%d", name,
                        selected ? object_getClassName(selected) : "nil", selected == dev);
      if (selected == dev && poster) poster_enable_sdr();
      [selected release];
      // Keep our original reference for the process lifetime, independently of
      // the private registration entry point's ownership convention.
   }
}
