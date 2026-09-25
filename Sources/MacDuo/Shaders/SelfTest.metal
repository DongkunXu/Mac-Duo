#include "Common.h"

/// Self-test only: the desktop blurred by a uniform Gaussian of `sigma` source pixels, used to
/// verify the pyramid's variance model against the analytic edge profile.
fragment float4 selfTestBlurFragment(FullscreenVertexOut in [[stage_in]],
                                     texture2d<float> source [[texture(0)]],
                                     texture2d<float> pyramid [[texture(1)]],
                                     constant BlurInfo& blur [[buffer(0)]],
                                     constant float& sigma [[buffer(1)]]) {
    return float4(mdBlurSample(source, pyramid, blur, in.uv, sigma).rgb, 1.0f);
}
