import Foundation

struct NowPlayingPeelSimulationInput: Equatable, Sendable {
    var progress: Float
    var touchY: Float
    var targetProgress: Float
    var normalizedVelocity: Float
    var isInteracting: Bool
    var reduceMotion: Bool

    static let closed = Self(
        progress: 0,
        touchY: 0.76,
        targetProgress: 0,
        normalizedVelocity: 0,
        isInteracting: false,
        reduceMotion: false
    )
}
