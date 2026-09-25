#include "Common.h"

/// Fullscreen triangle; `uv` has its origin at the top-left like the captured texture.
vertex FullscreenVertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenVertexOut out;
    out.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
    out.uv = float2(p.x, 1.0f - p.y);
    return out;
}

/// One pyramid step: filters `source` with a separable [1,5,10,10,5,1]/32 binomial kernel
/// centred on each destination pixel and writes the result at half resolution.
///
/// Taps per axis sit at ±0.8333 and ±2.5 source pixels from the destination centre. A bilinear
/// fetch at ±0.8333 blends the pixels at ±0.5 and ±1.5 in the ratio 2:1, giving weights 10 and 5;
/// ±2.5 falls on pixel centres with weight 1. Kernel variance: 1.25 source px² per axis.
kernel void pyramidDownsample(texture2d<float, access::sample> source [[texture(0)]],
                              texture2d<float, access::write> destination [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(destination.get_width(), destination.get_height());
    if (gid.x >= size.x || gid.y >= size.y) {
        return;
    }
    constexpr sampler linearClamp(address::clamp_to_edge, filter::linear);
    float2 sourceSize = float2(source.get_width(), source.get_height());
    float2 ratio = sourceSize / float2(size);
    float2 center = (float2(gid) + 0.5f) * ratio;
    float2 step = ratio * 0.5f;

    const float offsets[4] = { -2.5f, -0.8333333f, 0.8333333f, 2.5f };
    const float weights[4] = { 1.0f / 32.0f, 15.0f / 32.0f, 15.0f / 32.0f, 1.0f / 32.0f };

    float4 sum = 0.0f;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            float2 position = center + float2(offsets[x] * step.x, offsets[y] * step.y);
            sum += weights[x] * weights[y] * source.sample(linearClamp, position / sourceSize);
        }
    }
    destination.write(float4(sum.rgb, 1.0f), gid);
}
