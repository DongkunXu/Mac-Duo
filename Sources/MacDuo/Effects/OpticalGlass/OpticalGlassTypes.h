// Uniforms of the OpticalGlass effect, shared by Swift and Metal.
#ifndef OpticalGlassTypes_h
#define OpticalGlassTypes_h

#include <simd/simd.h>

// Lengths in millimetres on the physical panel. Keep simd_float2 members first.
typedef struct {
    simd_float2 outputSize;
    simd_float2 screenMM;
    float hingeOffsetMM;
    float eyeDistanceMM;
    float eyeLiftMM;
    float eyeLateralMM;
    float deltaRadians;
    float blurPerMM;
    float baseGapMM;
    float maxSigmaMM;
    float darkeningPerMM;
    float edgeBlack;
} OpticalGlassUniforms;

#endif
