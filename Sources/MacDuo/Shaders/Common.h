// Helpers shared by all effect shaders.
#pragma once

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Blur pyramid variance model (see Pyramid.metal):
// - each downsampling step applies a [1,5,10,10,5,1]/32 kernel per axis, adding 1.25 source-level px² of variance;
// - sampling a pyramid level with cubic B-spline reconstruction adds 1/3 level px².
// Overall level L = 0 is the full-resolution source; L ≥ 1 is pyramid mip L - 1.
// Effective variance of level L ≥ 1 in source px²: (1.25/3 + 1/3)·4^L − 1.25/3 = 0.75·4^L − 5/12.
#define MD_STEP_VARIANCE 1.25f
#define MD_SPLINE_VARIANCE (1.0f / 3.0f)

inline float mdLevelVariance(float level) {
    return (MD_STEP_VARIANCE / 3.0f + MD_SPLINE_VARIANCE) * exp2(2.0f * level) - MD_STEP_VARIANCE / 3.0f;
}

inline float4 mdSampleLinear(texture2d<float> tex, float2 uv, float lod) {
    constexpr sampler linearClamp(address::clamp_to_edge, filter::linear, mip_filter::nearest);
    return tex.sample(linearClamp, uv, level(lod));
}

/// Cubic B-spline reconstruction of one mip level using four bilinear fetches.
inline float4 mdSampleBSpline(texture2d<float> tex, float2 uv, uint lod) {
    float2 size = float2(tex.get_width(lod), tex.get_height(lod));
    float2 t = uv * size - 0.5f;
    float2 i = floor(t);
    float2 f = t - i;
    float2 f2 = f * f;
    float2 f3 = f2 * f;
    float2 w0 = (1.0f - 3.0f * f + 3.0f * f2 - f3) / 6.0f;
    float2 w1 = (4.0f - 6.0f * f2 + 3.0f * f3) / 6.0f;
    float2 w2 = (1.0f + 3.0f * f + 3.0f * f2 - 3.0f * f3) / 6.0f;
    float2 w3 = f3 / 6.0f;
    float2 g0 = w0 + w1;
    float2 g1 = w2 + w3;
    float2 p0 = (i - 1.0f + w1 / g0 + 0.5f) / size;
    float2 p1 = (i + 1.0f + w3 / g1 + 0.5f) / size;
    float l = float(lod);
    float4 a = mdSampleLinear(tex, float2(p0.x, p0.y), l);
    float4 b = mdSampleLinear(tex, float2(p1.x, p0.y), l);
    float4 c = mdSampleLinear(tex, float2(p0.x, p1.y), l);
    float4 d = mdSampleLinear(tex, float2(p1.x, p1.y), l);
    return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
}

/// Samples the desktop blurred by a Gaussian of standard deviation `sigma` (source pixels),
/// interpolating between pyramid levels linearly in variance. `sigma` of 0 returns the source.
inline float4 mdBlurSample(texture2d<float> source, texture2d<float> pyramid, constant BlurInfo& info,
                           float2 uv, float sigma) {
    float variance = max(sigma, 0.0f) * sigma;
    float firstLevel = mdLevelVariance(1.0f);
    float4 sharp = mdSampleLinear(source, uv, 0.0f);
    if (variance <= 0.0f || info.levelCount < 1.0f) {
        return sharp;
    }
    if (variance < firstLevel) {
        return mix(sharp, mdSampleBSpline(pyramid, uv, 0), variance / firstLevel);
    }
    float scale = MD_STEP_VARIANCE / 3.0f + MD_SPLINE_VARIANCE;
    float level = floor(0.5f * log2((variance + MD_STEP_VARIANCE / 3.0f) / scale));
    level = clamp(level, 1.0f, info.levelCount);
    if (level >= info.levelCount) {
        return mdSampleBSpline(pyramid, uv, uint(info.levelCount) - 1);
    }
    float low = mdLevelVariance(level);
    float high = mdLevelVariance(level + 1.0f);
    float fraction = saturate((variance - low) / (high - low));
    uint mip = uint(level) - 1;
    return mix(mdSampleBSpline(pyramid, uv, mip), mdSampleBSpline(pyramid, uv, mip + 1), fraction);
}

/// Coverage of the unit rectangle for a pixel at `uv`, with edges softened by `feather` (uv units).
/// A pixel fully inside with a one-pixel feather returns exactly 1.
inline float mdRectCoverage(float2 uv, float2 feather) {
    float2 inside = smoothstep(0.0f, 1.0f, uv / feather + 0.5f) * smoothstep(0.0f, 1.0f, (1.0f - uv) / feather + 0.5f);
    return inside.x * inside.y;
}
