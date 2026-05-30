import Foundation

struct NowPlayingPeelSimulationFrame: Sendable {
    var vertices: [NowPlayingPeelSimulationVertex]
    var indices: [UInt16]
    var progress: Float
}
