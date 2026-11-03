/* SPDX-License-Identifier: MIT */
#ifdef BG_TL_SITE
#undef bg_lock
#define bg_lock() bg_lock_at(BG_TL_SITE(2, __LINE__))
#endif
struct bg_shader_writes { struct rwa_texture *texture[BG_MAX_WRITE_DESTINATIONS]; unsigned count; };
static int bg_collect_destination(void *context,struct rwa_texture *texture)
{
   struct bg_shader_writes *set=context;
   unsigned surface=rwa_texture_surface_id(texture);
   if (!surface) return 0;
   for (unsigned i=0;i<set->count;i++)
      if (rwa_texture_surface_id(set->texture[i]) == surface) return 0;
   if (set->count == BG_MAX_WRITE_DESTINATIONS) return -1;
   set->texture[set->count++]=texture;
   return 0;
}
- (BOOL)bgCollectWrites:(BGWork *)w
{
   if (_admissionFailed) return NO;
   if (w->kind == BG_WORK_DRAW || w->kind == BG_WORK_CLEAR) {
      for (unsigned i=0;i<w->color_count;i++) [self bgTicketFor:w->color[i]];
      [self bgTicketFor:w->depth];
   } else if (w->kind == BG_WORK_TEXCOPY || w->kind == BG_WORK_BUF2TEX ||
              w->kind == BG_WORK_RESOLVE || w->kind == BG_WORK_MIPMAPS)
      [self bgTicketFor:w->dst];
   if (_admissionFailed) return NO;
   if (w->kind != BG_WORK_DISPATCH && w->kind != BG_WORK_DRAW) return YES;
   struct rwa_buffer *vb[BG_MAX_BINDINGS]={0}, *fb[BG_MAX_BINDINGS]={0};
   struct rwa_buffer_bind vt[BG_MAX_BINDINGS]={0},ft[BG_MAX_BINDINGS]={0};
   struct rwa_texture *textures[BG_MAX_TEX]={0};
   char why[256]={0};
   struct bg_shader_writes writes={0};
   /* Only the argument-buffer records need a lock here: the BGWork retains the
    * buffers/textures, _buf never changes, and _tex is stable unless the optional
    * shadow is on (then keep bg_lock, because bgShadowLocked swaps _tex under it). */
   int shadow = bg_shadow_requested();
   if (shadow) bg_lock();
   bg_argbuf_lock();
   for (unsigned i=0;i<w->vcount;i++) {
      vb[i]=[(BGMTLBuffer *)w->vbuffers[i] rwaAdmissionBuffer];
      vt[i]=(struct rwa_buffer_bind){vb[i],w->voffsets[i]};
   }
   for (unsigned i=0;i<w->count;i++) {
      fb[i]=[(BGMTLBuffer *)w->buffers[i] rwaAdmissionBuffer];
      ft[i]=(struct rwa_buffer_bind){fb[i],w->offsets[i]};
   }
   for (unsigned i=0;i<w->texture_count;i++) textures[i]=[(BGMTLTexture *)w->textures[i] rwaAdmissionTexture];
   struct rwa_bindings vertex={.buffers=vb,.buffer_count=w->vcount};
   struct rwa_bindings fragment={.buffers=fb,.buffer_count=w->count,.textures=textures,.texture_count=w->texture_count};
   int result=w->kind == BG_WORK_DISPATCH ?
      rwa_compute_write_destinations(w->pipeline->_compute,&fragment,ft,w->count,bg_collect_destination,&writes,why,sizeof(why)) :
      rwa_render_write_destinations(((BGMTLRenderPipeline *)w->render)->_render,&vertex,vt,w->vcount,&fragment,ft,w->count,bg_collect_destination,&writes,why,sizeof(why));
   bg_argbuf_unlock();
   if (shadow) bg_unlock();
   // Do not wait for another producer while holding the recursive context lock.
   // At replay, the outer CB lock stays held and _committed forbids retry waits.
   if (!result)
      for (unsigned i=0;i<writes.count;i++) if (![self bgAdmitRaw:writes.texture[i]]) break;
   if (result && !_admissionFailed) [self bgAdmissionReject:[NSString stringWithUTF8String:why]];
   return !_admissionFailed;
}
#ifdef BG_TL_SITE
#undef bg_lock
#define bg_lock() bg_lock_at(BG_TL_SITE(0, __LINE__))
#endif
