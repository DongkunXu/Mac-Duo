#include "../../Shaders/Common.h"
#include "OpticalGlassTypes.h"

// Frosted-glass optics in millimetres. Side view aligned with the content plane: `a` runs up the
// plane from the hinge, `n` is its normal towards the viewer, and the desktop lies on n = 0. A pixel
// at height s on the panel sits on the glass at r = hingeOffset + s, rotated by δ:
// G = r·(cos δ, −sin δ). Each glass pixel shows the plane point on the eye's ray through it, blurred
// and darkened by the distance along that ray. At δ = 0 the mapping is the identity. The glass
// never tilts past the content plane (δ > 0 draws sharp).
fragment float4 opticalGlassFragment(FullscreenVertexOut in [[stage_in]],
                                     texture2d<float> source [[texture(0)]],
                                     texture2d<float> pyramid [[texture(1)]],
                                     constant BlurInfo& blur [[buffer(0)]],
                                     constant OpticalGlassUniforms& u [[buffer(1)]]) {
    float width = u.screenMM.x;
    float height = u.screenMM.y;
    float2 pixel = in.position.xy;
    float xMM = pixel.x / u.outputSize.x * width;
    float s = (1.0f - pixel.y / u.outputSize.y) * height;

    float delta = min(u.deltaRadians, 0.0f);

    float r = u.hingeOffsetMM + s;
    float glassA = r * cos(delta);
    float glassN = -r * sin(delta);
    float eyeA = u.hingeOffsetMM + 0.5f * height + u.eyeLiftMM;
    float eyeN = u.eyeDistanceMM;
    float eyeX = 0.5f * width + u.eyeLateralMM;

    float denominator = eyeN - glassN;
    if (denominator <= 0.02f * eyeN) {
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }
    float t = eyeN / denominator;
    float hitA = eyeA + t * (glassA - eyeA);
    float hitX = eyeX + t * (xMM - eyeX);
    float2 uv = float2(hitX / width, 1.0f - (hitA - u.hingeOffsetMM) / height);

    float gap = abs(t - 1.0f) * length(float3(xMM - eyeX, glassA - eyeA, glassN - eyeN));
    float onset = smoothstep(0.0f, 0.035f, abs(delta));
    float sigmaMM = min(u.blurPerMM * (gap + u.baseGapMM * onset), u.maxSigmaMM);
    float2 pixelsPerMM = blur.sourceSize / u.screenMM;
    float sigma = sigmaMM * 0.5f * (pixelsPerMM.x + pixelsPerMM.y);

    float4 color = mdBlurSample(source, pyramid, blur, saturate(uv), sigma);
    if (u.edgeBlack > 0.5f) {
        float2 feather = max(3.0f * sigma / blur.sourceSize, fwidth(uv));
        color.rgb *= mdRectCoverage(uv, feather);
    }
    color.rgb *= exp(-u.darkeningPerMM * gap);
    return float4(color.rgb, 1.0f);
}
