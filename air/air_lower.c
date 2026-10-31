/*
 * Copyright © 2026 Darwin on redwood contributors (air_nir_lower_for_gallium,
 *   moved from air_metal.c) and jasmine contributors
 * SPDX-License-Identifier: MIT
 * jasmine: NIR lowerings the AIR runtime applies before handing a shader to
 * Gallium, including those for GPUs without what Metal assumes (Adreno 5xx).
 * Shared by the runtime (air_metal.c) and the offline compiler (air2ir3.c),
 * so the corpus compiles exactly what the device would.
 */
#include "nir.h"
#include "nir_builder.h"
#include "nir_air.h"

/* a5xx Gallium has no VS SSBO bindings. Read-only vertex buffers can use UBO
 * loads; the runtime refuses writes and bounds the bindings. */
static bool
vertex_ssbo_to_ubo(nir_builder *b, nir_intrinsic_instr *in, void *data)
{
   (void)data;
   if (in->intrinsic != nir_intrinsic_load_ssbo)
      return false;
   b->cursor = nir_before_instr(&in->instr);
   nir_def *v = nir_load_ubo(b, in->def.num_components, in->def.bit_size,
                           in->src[0].ssa, in->src[1].ssa,
                           .align_mul = nir_intrinsic_align_mul(in),
                           .align_offset = nir_intrinsic_align_offset(in),
                           .range_base = 0, .range = ~0u);
   nir_def_rewrite_uses(&in->def, v);
   nir_instr_remove(&in->instr);
   return true;
}

bool
air_nir_lower_vertex_ssbo_to_ubo(nir_shader *vs)
{
   return nir_shader_intrinsics_pass(vs, vertex_ssbo_to_ubo, nir_metadata_control_flow, NULL);
}

/* A `[[color(n)]]` read (load_output with fb_fetch_output, always 4 x f32 from
 * air_to_nir) becomes a texel fetch of the attachment at the fragment's pixel. */
static bool
lower_attachment_read(nir_builder *b, nir_intrinsic_instr *in, void *data)
{
   const unsigned *units = data;
   if (in->intrinsic != nir_intrinsic_load_output ||
       !nir_intrinsic_io_semantics(in).fb_fetch_output) return false;
   unsigned target = nir_intrinsic_io_semantics(in).location - FRAG_RESULT_DATA0;
   b->cursor = nir_before_instr(&in->instr);
   nir_def *pos = nir_f2i32(b, nir_channels(b, nir_load_frag_coord(b), 3));
   nir_tex_instr *tex = nir_tex_instr_create(b->shader, 2);
   tex->op = nir_texop_txf;
   tex->sampler_dim = GLSL_SAMPLER_DIM_2D;
   tex->dest_type = nir_type_float32;
   tex->coord_components = 2;
   tex->texture_index = tex->sampler_index = units[target];
   tex->src[0].src_type = nir_tex_src_coord;
   tex->src[0].src = nir_src_for_ssa(pos);
   tex->src[1].src_type = nir_tex_src_lod;
   tex->src[1].src = nir_src_for_ssa(nir_imm_int(b, 0));
   nir_def_init(&tex->instr, &tex->def, 4, 32);
   nir_builder_instr_insert(b, &tex->instr);
   nir_def_rewrite_uses(&in->def, &tex->def);
   nir_instr_remove(&in->instr);
   return true;
}

/* Each target the shader really reads gets the highest texture/sampler unit no
 * texture instruction of it names. Units, not declared resources: QuartzCore's
 * uber fragment shader declares textures up to 14, most of which its function
 * constants leave unread, and a resource bound at a unit the shader never
 * samples is overwritten harmlessly by the attachment at the draw. Reads the
 * function constants removed need nothing at all. */
int
air_nir_lower_attachment_reads(nir_shader *fs, unsigned num_units, unsigned units[4])
{
   unsigned reads = 0;
   uint32_t used = 0;
   nir_foreach_function_impl(impl, fs) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            if (instr->type == nir_instr_type_tex) {
               nir_tex_instr *tex = nir_instr_as_tex(instr);
               if (nir_tex_instr_src_index(tex, nir_tex_src_texture_offset) >= 0 ||
                   nir_tex_instr_src_index(tex, nir_tex_src_sampler_offset) >= 0 ||
                   nir_tex_instr_src_index(tex, nir_tex_src_texture_handle) >= 0 ||
                   nir_tex_instr_src_index(tex, nir_tex_src_sampler_handle) >= 0)
                  used = ~0u;   /* an index chosen at run time may be any unit */
               if (tex->texture_index < 32)
                  used |= 1u << tex->texture_index;
               if (tex->sampler_index < 32)
                  used |= 1u << tex->sampler_index;
               continue;
            }
            if (instr->type != nir_instr_type_intrinsic)
               continue;
            nir_intrinsic_instr *in = nir_instr_as_intrinsic(instr);
            if (in->intrinsic == nir_intrinsic_load_output &&
                nir_intrinsic_io_semantics(in).fb_fetch_output)
               reads |= 1u << (nir_intrinsic_io_semantics(in).location - FRAG_RESULT_DATA0);
         }
      }
   }
   if (reads & ~15u)
      return -1;
   int unit = (int)MIN2(num_units, 32) - 1;
   for (unsigned i = 0; i < 4; i++) {
      if (!(reads & (1u << i)))
         continue;
      while (unit >= 0 && (used & (1u << unit)))
         unit--;
      if (unit < 0)
         return -1;
      units[i] = unit--;
   }
   nir_shader_intrinsics_pass(fs, lower_attachment_read, nir_metadata_control_flow, units);
   fs->info.fs.uses_fbfetch_output = false;
   fs->info.fs.fbfetch_coherent = false;
   for (unsigned i = 0; i < 4; i++) {
      fs->info.outputs_read &= ~BITFIELD64_BIT(FRAG_RESULT_DATA0 + i);
      if (reads & (1u << i)) {
         BITSET_SET(fs->info.textures_used, units[i]);
         BITSET_SET(fs->info.samplers_used, units[i]);
      }
   }
   return (int)reads;
}

/* What a Gallium driver expects of a shader it is handed: NIR's own system values
 * lowered to the hardware's, and I/O as intrinsics rather than variables. This was
 * finalize_for_gallium's in air_metal.c (also air_run.c's, and in tools/mesa/air-ir3.patch);
 * jasmine's air2ir3 made the fourth copy, so it is one function of the frontend now.
 */
static unsigned
type_size_vec4(const struct glsl_type *type, bool bindless)
{
   return glsl_count_attribute_slots(type, false);
}

static void lower_image_load_access(nir_shader *nir);
static bool widen_image_store(nir_builder *b, nir_intrinsic_instr *in, void *data);

void
air_nir_lower_for_gallium(nir_shader *nir)
{
   lower_image_load_access(nir);
   nir_shader_intrinsics_pass(nir, widen_image_store, nir_metadata_control_flow, NULL);
   NIR_PASS(_, nir, nir_lower_system_values);
   /* An options struct of all-false and not NULL, which are not the same thing here and
    * the difference is a trap. nir_lower_system_values *introduces*
    * load_base_workgroup_id when it lowers SYSTEM_VALUE_WORKGROUP_ID, and the only
    * thing that removes it again is
    *
    *     if (options && !options->has_base_workgroup_id)
    *        return nir_imm_zero(...);
    *
    * so NULL reads as "the driver has base workgroup ids" -- the opposite of what is
    * wanted -- and the intrinsic survives into the backend. With softpipe that is an
    * assertion in nir_to_tgsi rather than a message, and it stopped every kernel that
    * asks for its workgroup id. Zero is also the right answer here: rwa_dispatch
    * (air_metal.c) launches its grid from the origin, as Metal's own dispatch does.
    */
   static const nir_lower_compute_system_values_options cs_options = { 0 };
   NIR_PASS(_, nir, nir_lower_compute_system_values, &cs_options);
   /*
    * nir_lower_io_use_interpolated_input_intrinsics, and WITHOUT it every varying this
    * library drew was FLAT on the Adreno while softpipe interpolated it -- the mistake
    * that looked like a vertically flipped picture for three boots (docs/metal.md 10.26,
    * 10.32). Mesa's own comment on the flag says why: without it nir_lower_io "generates
    * regular load_input intrinsics and interpolation information must be inferred from
    * the list of input nir_variables", and the two consumers infer it from different
    * places. nir_to_tgsi reads each FS input's variable (INTERP_MODE_SMOOTH, as the
    * frontend sets it); ir3's setup_input does `so->inputs[n].flat = !coord` and builds
    * `coord` only for load_interpolated_input, so a plain load_input is flat.
    *
    * Nothing caught it because the only draws whose varying VARIES are Apple's
    * texturedVertex2D/3D feeding texturedFragment*: the generated vertex stage hands
    * every vertex the same texture coordinate (RWA_TEX_* in air_metal.c), and over a constant
    * flat and smooth are the same number.
    */
   NIR_PASS(_, nir, nir_lower_io, nir_var_shader_in | nir_var_shader_out,
            type_size_vec4, nir_lower_io_use_interpolated_input_intrinsics);
}

/* Whether the shader writes SSBO `index`: a store or an atomic naming it, or
 * naming any index chosen at run time. */
bool
air_nir_writes_ssbo(nir_shader *nir, unsigned index)
{
   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            if (instr->type != nir_instr_type_intrinsic)
               continue;
            nir_intrinsic_instr *in = nir_instr_as_intrinsic(instr);
            nir_src *buf;
            if (in->intrinsic == nir_intrinsic_store_ssbo)
               buf = &in->src[1];
            else if (in->intrinsic == nir_intrinsic_ssbo_atomic ||
                     in->intrinsic == nir_intrinsic_ssbo_atomic_swap)
               buf = &in->src[0];
            else
               continue;
            if (!nir_src_is_const(*buf) || nir_src_as_uint(*buf) == index)
               return true;
         }
      }
   }
   return false;
}

/* The access an image load needs on a5xx. ir3 reads an image through the
 * texture path only for an image_load marked CAN_REORDER and otherwise through
 * LDIB, which needs the image's dimensions as driver constants; but its constant
 * scan (ir3_nir_scan_driver_consts) reserves those only for COHERENT loads. A
 * load marked neither -- every load this frontend makes -- took LDIB without
 * them: an assertion in a debug build, a read of the wrong constants in a
 * release one. GL never meets it because st/mesa marks read-only images
 * CAN_REORDER. So: a load of an image the shader never writes may reorder (the
 * texture path, as GL), and a load of one it writes is COHERENT (LDIB, with its
 * dimensions). Run-time image indices count as writing every image. */
static bool
image_load_access(nir_builder *b, nir_intrinsic_instr *in, void *data)
{
   (void)b;
   const uint32_t *written = data;
   if (in->intrinsic != nir_intrinsic_image_load ||
       (nir_intrinsic_access(in) & (ACCESS_CAN_REORDER | ACCESS_COHERENT)))
      return false;
   bool may_be_written = !nir_src_is_const(in->src[0]) || *written == ~0u ||
                         nir_src_as_uint(in->src[0]) >= 32 ||
                         (*written & (1u << nir_src_as_uint(in->src[0])));
   nir_intrinsic_set_access(in, nir_intrinsic_access(in) |
                                (may_be_written ? ACCESS_COHERENT
                                                : ACCESS_CAN_REORDER | ACCESS_NON_WRITEABLE));
   return true;
}

static void
lower_image_load_access(nir_shader *nir)
{
   uint32_t written = 0;
   nir_foreach_function_impl(impl, nir) {
      nir_foreach_block(block, impl) {
         nir_foreach_instr(instr, block) {
            if (instr->type != nir_instr_type_intrinsic)
               continue;
            nir_intrinsic_instr *in = nir_instr_as_intrinsic(instr);
            if (in->intrinsic != nir_intrinsic_image_store &&
                in->intrinsic != nir_intrinsic_image_atomic &&
                in->intrinsic != nir_intrinsic_image_atomic_swap)
               continue;
            if (!nir_src_is_const(in->src[0]) || nir_src_as_uint(in->src[0]) >= 32)
               written = ~0u;
            else
               written |= 1u << nir_src_as_uint(in->src[0]);
         }
      }
   }
   nir_shader_intrinsics_pass(nir, image_load_access, nir_metadata_all, &written);
}

/* A 16-bit image store value widened to 32 bits. a5xx's STIB takes full
 * registers only (ir3_validate: "!(srcs[1]->flags & IR3_REG_HALF)"); a typed
 * store converts to the image's format either way, which is how GL stores on
 * a5xx, so this is correct on every GPU. QuartzCore's inplace_copy_lph writes
 * half4. */
static bool
widen_image_store(nir_builder *b, nir_intrinsic_instr *in, void *data)
{
   (void)data;
   if (in->intrinsic != nir_intrinsic_image_store || nir_src_bit_size(in->src[3]) != 16)
      return false;
   nir_alu_type t = nir_intrinsic_src_type(in);
   b->cursor = nir_before_instr(&in->instr);
   nir_def *v = in->src[3].ssa;
   nir_alu_type base = nir_alu_type_get_base_type(t);
   v = base == nir_type_float ? nir_f2f32(b, v) : base == nir_type_int ? nir_i2i32(b, v) : nir_u2u32(b, v);
   nir_src_rewrite(&in->src[3], v);
   nir_intrinsic_set_src_type(in, base | 32);
   return true;
}
