/*
 * Copyright © 2026 jasmine contributors
 * SPDX-License-Identifier: MIT
 * jasmine: offline AIR -> NIR -> ir3 compiler for Mesa 26.2.5.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nir.h"
#include "nir_builder.h"
#include "nir_air.h"
#include "ir3/ir3_compiler.h"
#include "ir3/ir3_shader.h"
#include "ir3/ir3_nir.h"
#include "util/sweet_profile.h"

/* The shared ir3 variant path has jasmine profiling scopes. This offline
 * executable deliberately has no SweetGPU backend or kernel profiling sink. */
void
sweet_profile_enter(struct sweet_profile_scope *scope, enum sweet_profile_id id)
{
   memset(scope, 0, sizeof(*scope));
   (void)id;
}

void
sweet_profile_leave(struct sweet_profile_scope *scope)
{
   (void)scope;
}

int
main(int argc, char **argv)
{
   if (argc < 2 || argc > 4) {
      fprintf(stderr, "usage: air2ir3 FILE [FUNCTION [GPU_ID]] (default GPU: 512)\n");
      return 2;
   }
   unsigned gpu = 512;
   if (argc == 4) {
      char *end;
      errno = 0;
      unsigned long parsed = strtoul(argv[3], &end, 0);
      if (errno || *end || parsed > 9999 || !parsed) {
         fprintf(stderr, "invalid GPU_ID: %s\n", argv[3]);
         return 2;
      }
      gpu = parsed;
   }
   FILE *fp = fopen(argv[1], "rb");
   if (!fp) {
      perror(argv[1]);
      return 2;
   }
   if (fseek(fp, 0, SEEK_END) || ftell(fp) <= 0) {
      fprintf(stderr, "cannot size nonempty input: %s\n", argv[1]);
      fclose(fp);
      return 2;
   }
   size_t size = ftell(fp);
   rewind(fp);
   void *data = malloc(size);
   if (!data || fread(data, 1, size, fp) != size) {
      fprintf(stderr, "cannot read input: %s\n", argv[1]);
      fclose(fp);
      free(data);
      return 2;
   }
   fclose(fp);
   void *ctx = ralloc_context(NULL);
   const void *bitcode = data;
   size_t bitcode_size = size;
   const char *entry = argc >= 3 ? argv[2] : NULL;
   const char *error = NULL;
   int result = 1;
   struct ir3_compiler *compiler = NULL;
   struct ir3_shader *shader = NULL;
   glsl_type_singleton_init_or_ref();
   if (size >= 4 && !memcmp(data, "MTLB", 4)) {
      struct air_metallib lib;
      if (!air_metallib_parse(ctx, data, size, &lib, &error)) {
         fprintf(stderr, "metallib: %s\n", error);
         goto done;
      }
      unsigned pick = lib.num_functions;
      for (unsigned i = 0; i < lib.num_functions; i++) {
         if (!entry || !strcmp(entry, lib.functions[i].name)) {
            pick = i;
            break;
         }
      }
      if (pick == lib.num_functions) {
         fprintf(stderr, "metallib: function not found: %s\n", entry ? entry : "(first)");
         goto done;
      }
      bitcode = lib.functions[pick].bitcode;
      bitcode_size = lib.functions[pick].bitcode_size;
      entry = lib.functions[pick].name;
   }
   const struct fd_dev_id id = { .gpu_id = gpu };
   const struct fd_dev_info *dev_info = fd_dev_info_raw(&id);
   if (!dev_info) {
      fprintf(stderr, "unsupported GPU: %u\n", gpu);
      goto done;
   }
   compiler = ir3_compiler_create(NULL, &id, dev_info,
      &(struct ir3_compiler_options){ .disable_cache = true });
   struct air_constant_value *constants;
   unsigned count = air_module_function_constants(ctx, bitcode, bitcode_size, &constants);
   const struct air_to_nir_options options = {
      .constants = constants, .num_constants = count, .library_wrapper = true,
   };
   struct air_shader_info info;
   nir_shader *nir = air_to_nir(ctx, bitcode, bitcode_size, entry, &options,
                               ir3_get_compiler_options(compiler), &info, &error);
   if (!nir) {
      fprintf(stderr, "NIR FAIL: %s\n", error);
      goto done;
   }
   printf("NIR OK: %s stage=%s constants=%u (zero defaults)\n",
          info.entry_point, mesa_shader_stage_name(nir->info.stage), count);
   fflush(stdout);
   /* jasmine: from here on the same steps as the runtime (air_metal.c) on a
    * freedreno screen, so a function compiles here exactly when the device would
    * compile it: rwa_render_create's a5xx lowerings, compute_state_for's fixed
    * threadgroup, finalize_for_gallium (fs_position_is_sysval: only the shared
    * passes), then freedreno's ir3_shader_state_create, which runs no
    * ir3_finalize_nir, and the initial variant with a zero key. */
   if (gpu < 600 && nir->info.stage == MESA_SHADER_FRAGMENT && info.fbfetch_targets) {
      unsigned units[4];
      int read = air_nir_lower_attachment_reads(nir, 16, units);
      if (read < 0) {
         fprintf(stderr, "ir3 FAIL: a5xx attachment feedback supports color targets 0..3, each on a "
                         "texture/sampler unit the shader leaves free\n");
         goto done;
      }
      printf("a5xx: attachment reads of targets 0x%x lowered to texture units", (unsigned)read);
      for (unsigned i = 0; i < 4; i++)
         if (read & (1 << i))
            printf(" %u", units[i]);
      printf("\n");
   }
   if (gpu < 600 && nir->info.stage == MESA_SHADER_VERTEX) {
      unsigned ubos = nir->info.num_ubos;
      for (unsigned i = 0; i < info.num_resources; i++) {
         const struct air_resource *r = &info.resources[i];
         if (r->kind != AIR_RESOURCE_DEVICE_BUFFER)
            continue;
         if (r->write && air_nir_writes_ssbo(nir, r->index)) {
            fprintf(stderr, "ir3 FAIL: a5xx vertex device buffer %u cannot be represented as a read-only UBO\n",
                    r->index);
            goto done;
         }
         ubos = MAX2(ubos, r->index + 1);
      }
      air_nir_lower_vertex_ssbo_to_ubo(nir);
      nir->info.num_ssbos = 0;
      nir->info.num_ubos = ubos;
   }
   if (nir->info.stage == MESA_SHADER_COMPUTE) {
      /* Metal's threadgroup size is a dispatch argument; the runtime compiles per
       * size. 8x8x1 stands in for the device's choice (a512 allows 512 threads). */
      nir->info.workgroup_size[0] = nir->info.workgroup_size[1] = 8;
      nir->info.workgroup_size[2] = 1;
      nir->info.workgroup_size_variable = false;
   }
   air_nir_lower_for_gallium(nir);
   shader = ir3_shader_from_nir(compiler, nir, &(struct ir3_shader_options){
      .api_wavesize = IR3_SINGLE_OR_DOUBLE, .real_wavesize = IR3_SINGLE_OR_DOUBLE,
   });
   shader->cs.req_local_mem = nir->info.shared_size;
   struct ir3_shader_variant *variant = ir3_shader_get_variant(
      shader, &(struct ir3_shader_key){}, false, true, NULL, NULL);
   if (!variant) {
      fprintf(stderr, "ir3 FAIL: compilation failed for a%u\n", gpu);
      goto done;
   }
   printf("ir3 OK: a%u %s\n", gpu, info.entry_point);
   /* get_variant compiles AND assembles, then destroys the temporary IR. */
   if (variant->disasm_info.disasm)
      fputs(variant->disasm_info.disasm, stdout);
   result = 0;
done:
   if (shader)
      ir3_shader_destroy(shader);
   if (compiler)
      ir3_compiler_destroy(compiler);
   ralloc_free(ctx);
   glsl_type_singleton_decref();
   free(data);
   return result;
}
