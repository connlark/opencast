import simd

struct NowPlayingMetalPeelVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
    var color: SIMD4<Float>
    var material: SIMD4<Float>
}
