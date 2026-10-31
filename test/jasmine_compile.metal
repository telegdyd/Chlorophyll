// SPDX-License-Identifier: MIT
// jasmine: offline compiler probes; compile success does not prove GPU correctness.
#include <metal_stdlib>
using namespace metal;

kernel void jasmine_add(device uint *out [[buffer(0)]],
                        uint id [[thread_position_in_grid]]) {
   out[id] = id + 7;
}
kernel void jasmine_u2f(device float *out [[buffer(0)]],
                        device uint *in [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
   out[id] = float(in[id]);
}
kernel void jasmine_byte(device uchar *out [[buffer(0)]],
                         uint id [[thread_position_in_grid]]) {
   out[id] = uchar(id);
}
kernel void jasmine_negative(device uint *out [[buffer(0)]],
                             device uint *in [[buffer(1)]],
                             uint id [[thread_position_in_grid]]) {
   if (id) out[id] = in[id - 1];
}
vertex float4 jasmine_vertex(uint id [[vertex_id]]) {
   return float4(float(id & 1), float(id >> 1), 0, 1);
}
fragment float4 jasmine_fragment() { return float4(1, 0.5, 0, 1); }
fragment float4 jasmine_fetch(float4 old [[color(0)]]) { return old * 0.5; }
