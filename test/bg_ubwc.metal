// SPDX-License-Identifier: MIT
#include <metal_stdlib>
using namespace metal;
struct UV { float4 pos [[position]]; };
vertex UV ubwc_vs(uint vid [[vertex_id]]) {
   UV v;
   v.pos = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0, 1);
   return v;
}
fragment float4 ubwc_solid(UV v [[stage_in]]) {
   return float4(0.25, 0.5, 0.75, 0.5);
}
fragment float4 ubwc_gradient(UV v [[stage_in]]) {
   return float4(fract(v.pos.x / 128.0), fract(v.pos.y / 256.0), 0.25, 1);
}
fragment float4 ubwc_noise(UV v [[stage_in]]) {
   uint n = uint(v.pos.x) + uint(v.pos.y) * 65537u;
   n = (n ^ (n >> 16)) * 1103515245u + 12345u;
   return float4(float(n & 255u), float((n >> 8) & 255u),
                 float((n >> 16) & 255u), 255.0) / 255.0;
}
fragment float4 ubwc_sample(UV v [[stage_in]], texture2d<float> t [[texture(0)]]) {
   return t.read(uint2(v.pos.xy));
}
