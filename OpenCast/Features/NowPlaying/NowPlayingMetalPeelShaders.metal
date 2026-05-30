#include <metal_stdlib>
using namespace metal;

struct NowPlayingMetalPeelVertex {
    float2 position;
    float2 texCoord;
    float4 color;
    float4 material;
};

struct NowPlayingMetalPeelUniforms {
    float progress;
    float touchY;
    uint reduceMotion;
    uint reserved;
};

struct NowPlayingMetalPeelRasterVertex {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
    float4 material;
};

vertex NowPlayingMetalPeelRasterVertex nowPlayingPeelVertex(
    uint vertexID [[vertex_id]],
    constant NowPlayingMetalPeelVertex *vertices [[buffer(0)]]
) {
    NowPlayingMetalPeelRasterVertex out;
    NowPlayingMetalPeelVertex input = vertices[vertexID];
    out.position = float4(input.position, 0, 1);
    out.texCoord = input.texCoord;
    out.color = input.color;
    out.material = input.material;
    return out;
}

fragment float4 nowPlayingPeelArtworkFragment(
    NowPlayingMetalPeelRasterVertex in [[stage_in]],
    texture2d<float> artwork [[texture(0)]],
    sampler artworkSampler [[sampler(0)]],
    constant NowPlayingMetalPeelUniforms &uniforms [[buffer(1)]]
) {
    float4 sampled = artwork.sample(artworkSampler, in.texCoord);
    float3 frontArtwork = sampled.rgb;
    if (uniforms.reduceMotion != 0) {
        return float4(frontArtwork, in.color.a);
    }

    float progress = saturate(uniforms.progress);
    float lift = saturate(in.material.x);
    float fold = saturate(in.material.y);
    float released = saturate(in.material.z);
    float tack = saturate(in.material.w);
    float touchFalloff = exp(-pow((in.texCoord.y - uniforms.touchY) * 3.1, 2.0));
    float foldMask = released * smoothstep(0.08, 0.86, fold) * smoothstep(0.08, 0.92, progress);
    float parkedBack = smoothstep(0.62, 0.96, progress) * released * (1.0 - tack);
    float backside = max(foldMask * (0.50 + 0.16 * touchFalloff + 0.22 * lift), parkedBack);
    float tackCrease = 1.0 - smoothstep(0.0, 0.016, abs(in.texCoord.x - 0.055));
    float hingeCrease = fold * released * (1.0 - tack);
    float highlight = fold * released * smoothstep(0.12, 0.94, progress);
    float rimHighlight = exp(-pow((in.texCoord.x - 0.985) * 62.0, 2.0)) * released * smoothstep(0.16, 0.88, progress);
    float gumLine = exp(-pow((in.texCoord.x - 0.94) * 48.0, 2.0)) * progress * released * fold;
    float shade = (0.010 * progress + 0.034 * backside + 0.046 * lift) * released;
    float2 fleckCell = floor(in.texCoord * float2(16.0, 20.0));
    float fleckHash = fract(sin(dot(fleckCell, float2(12.9898, 78.233))) * 43758.5453);
    float flecks = step(0.975, fleckHash) * backside * 0.018;
    float wrinkle = sin(in.texCoord.x * 18.0 + in.texCoord.y * 20.0 + progress * 4.0) * fold * released * 0.003;

    float3 paperBack = float3(0.986, 0.976, 0.944);
    float3 color = mix(frontArtwork, paperBack, saturate(backside * 1.10));
    color += float3(0.25, 0.22, 0.14) * flecks;
    color += float3(1.0, 0.98, 0.88) * highlight * (0.08 + lift * 0.20 + touchFalloff * 0.06);
    color += float3(1.0) * rimHighlight * (0.10 + 0.06 * touchFalloff);
    color += float3(0.34, 0.27, 0.16) * gumLine * 0.035;
    color -= float3(0.13, 0.09, 0.03) * hingeCrease * backside * 0.08;
    color -= float3(shade);
    color += float3(1.0) * tackCrease * backside * 0.030;
    color += float3(wrinkle);

    return float4(saturate(color), in.color.a);
}

fragment float4 nowPlayingPeelColorFragment(
    NowPlayingMetalPeelRasterVertex in [[stage_in]]
) {
    return in.color;
}
