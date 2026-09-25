// Structures shared by every effect, visible to Swift and Metal. Keep simd_float2 members first.
#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

typedef struct {
    simd_float2 sourceSize;
    // Size of pyramid mip 0 (half resolution).
    simd_float2 pyramidSize;
    float levelCount;
    float padding;
} BlurInfo;

#endif
