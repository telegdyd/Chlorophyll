// SPDX-License-Identifier: MIT
// jasmine: process-local registration, enabled through sweetenv or exec env.
// No state files, preferences or root bundle. Step 7 adds backboardd to the
// allowed processes; it still needs BGMTL_ENABLE=1, which only a temporary
// boot's sweetenv entry for backboardd supplies.
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
   const char *name = getprogname();
   if (!enable || strcmp(enable, "1") ||
       (strcmp(name, "bgmtl_registered_probe") && strcmp(name, "backboardd"))) return;
   fprintf(stderr, "BGMTL registration: enabled in %s\n", name);
   // The compositor's paths in libbgmtl (render tickets, odd-pitch sampled surfaces, BGR5A1): backboardd always wants them.
   if (!strcmp(name, "backboardd")) setenv("BGMTL_BB", "1", 0);
   // A/B switches without a new boot image: KEY=VALUE lines (FD_MESA_DEBUG=inorder, BGMTL_SHADOW=0, ...), set before
   // the device and its Mesa screen exist. The boot command line has no room left for them.
   FILE *ab = fopen("/private/var/tmp/bgmtl-bb.env", "r");
   if (ab) {
      char line[256];
      while (fgets(line, sizeof(line), ab)) {
         line[strcspn(line, "\r\n")] = 0;
         char *eq = strchr(line, '=');
         if (!eq || eq == line) continue;
         *eq = 0;
         setenv(line, eq + 1, 1);
         fprintf(stderr, "BGMTL registration: %s=%s (bgmtl-bb.env)\n", line, eq + 1);
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
      [selected release];
      // Keep our original reference for the process lifetime, independently of
      // the private registration entry point's ownership convention.
   }
}
