// SPDX-License-Identifier: MIT
// Render test shaders for the BGMTLDevice probe: a coloured triangle and a textured quad.
#include <metal_stdlib>
using namespace metal;

struct V { float4 pos [[position]]; float4 color; float2 uv; };

// positions and colours from buffer(0): float4 pos, float4 color per vertex (stride 32)
vertex V bg_vs(uint vid [[vertex_id]], device const float4 *data [[buffer(0)]])
{
   V v;
   v.pos = data[vid * 2];
   v.color = data[vid * 2 + 1];
   v.uv = v.pos.xy * 0.5 + 0.5;
   return v;
}

fragment float4 bg_fs_color(V in [[stage_in]]) { return in.color; }

// A circle crossing the quad's shared triangle edge. Derivatives there need
// helper lanes even when no texture instruction requests an implicit LOD.
fragment half4 bg_fs_quad_helpers(V in [[stage_in]])
{
   float2 p = in.uv * 2.0 - 1.0;
   float d = dot(p, p);
   return half4(saturate((0.5625 - d) / max(fwidth(d), 0.0001) + 0.5));
}

fragment float4 bg_fs_tex(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
   return t.sample(s, in.uv);
}

// the same, with the sampler written into the shader (a constexpr sampler: AIR's inline sampler state), as CoreAnimation does
fragment float4 bg_fs_tex_inline(V in [[stage_in]], texture2d<float> t [[texture(0)]])
{
   constexpr sampler s(filter::nearest, address::clamp_to_edge);
   return t.sample(s, in.uv);
}

// linear filtering, an explicit lod and a constant-buffer offset: the shape of most of CoreAnimation's taps
struct U { float2 off; };
fragment float4 bg_fs_tex_linear(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant U &u [[buffer(1)]])
{
   return t.sample(s, in.uv + u.off, level(0));
}

// the same texture at a high slot, as CoreAnimation's shaders have it ([[texture(3)]])
fragment float4 bg_fs_tex3(V in [[stage_in]], texture2d<float> t [[texture(3)]], sampler s [[sampler(0)]])
{
   return t.sample(s, in.uv, level(0));
}

// a fragment stage with the varyings of CoreAnimation's std_vert0_*: color (float4) and texcoord0_0 (float2)
struct CAV { float4 pos [[position]]; float4 color; float2 texcoord0_0; };
fragment float4 bg_fs_ca_color(CAV in [[stage_in]]) { return in.color; }

// jasmine: two-attachment feedback, exact float arithmetic over successive draws.
struct Feedback { float4 a [[color(0)]]; float4 b [[color(1)]]; };
// Seed both attachments with an ordinary draw so the following fetch exercises
// a retained barrier, with optional GMEM still armed (no empty-batch fallback).
fragment Feedback bg_fs_feedback_seed(V in [[stage_in]])
{
   Feedback f; f.a = float4(10,20,30,1); f.b = float4(11,21,31,1); return f;
}
fragment Feedback bg_fs_feedback(V in [[stage_in]], float4 a [[color(0)]], float4 b [[color(1)]])
{
   Feedback f; f.a = a + float4(1, 2, 3, 0); f.b = b + float4(3, 2, 1, 0); return f;
}
