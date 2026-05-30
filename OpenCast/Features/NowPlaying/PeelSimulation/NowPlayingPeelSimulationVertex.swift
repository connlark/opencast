import Foundation
import simd

struct NowPlayingPeelSimulationVertex: Equatable, Sendable {
    var position: SIMD3<Float>
    var restPosition: SIMD3<Float>
    var uv: SIMD2<Float>
    var lift: Float
    var foldIntensity: Float
    var released: Float
    var tack: Float
}
