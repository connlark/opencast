import Foundation

struct NowPlayingPeelSimulationParameters: Equatable, Sendable {
    var columns: Int
    var rows: Int
    var tackWidth: Float
    var structuralCompliance: Float
    var shearCompliance: Float
    var bendingCompliance: Float
    var adhesionCompliance: Float
    var dragCompliance: Float
    var damping: Float
    var solverIterations: Int
    var releaseHysteresis: Float
    var settleStiffness: Float
    var settleDamping: Float

    static let `default` = Self(
        columns: 30,
        rows: 26,
        tackWidth: 0.055,
        structuralCompliance: 0.000_002,
        shearCompliance: 0.000_010,
        bendingCompliance: 0.000_070,
        adhesionCompliance: 0.000_004,
        dragCompliance: 0.000_15,
        damping: 0.82,
        solverIterations: 7,
        releaseHysteresis: 0.026,
        settleStiffness: 48,
        settleDamping: 10.5
    )
}
