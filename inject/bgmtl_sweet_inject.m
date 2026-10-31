// SPDX-License-Identifier: MIT
// jasmine: process-local registration, enabled through sweetenv or exec env.
// No state files, preferences, root bundle, or compositor allow-list.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern id bgmtl_create_device(void);

// Keep unknown selectors and backend failures visible in the probe's capture.
void bgmtl_note_unimplemented(const char *sel)
{ fprintf(stderr, "BGMTL UNIMPLEMENTED: %s\n", sel); }
void bgmtl_note_failure(const char *why)
{ fprintf(stderr, "BGMTL command buffer failure: %s\n", why ? why : "?"); }
void bgmtl_note_line(const char *line)
{ fprintf(stderr, "BGMTL: %s\n", line); }

__attribute__((constructor)) static void
bgmtl_sweet_init(void)
{
   const char *enable = getenv("BGMTL_ENABLE");
   if (!enable || strcmp(enable, "1") ||
       strcmp(getprogname(), "bgmtl_registered_probe")) return;
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
      [selected release];
      // Keep our original reference for the process lifetime, independently of
      // the private registration entry point's ownership convention.
   }
}
