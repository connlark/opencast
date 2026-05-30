import Foundation

public struct VoiceBoostLoudnessAnalysis: Equatable, Sendable {
    public var momentaryLUFS: [Double]
    public var shortTermLUFS: [Double]
    public var integratedLUFS: Double?
    public var ungatedIntegratedLUFS: Double?

    public init(
        momentaryLUFS: [Double],
        shortTermLUFS: [Double],
        integratedLUFS: Double?,
        ungatedIntegratedLUFS: Double?
    ) {
        self.momentaryLUFS = momentaryLUFS
        self.shortTermLUFS = shortTermLUFS
        self.integratedLUFS = integratedLUFS
        self.ungatedIntegratedLUFS = ungatedIntegratedLUFS
    }
}
