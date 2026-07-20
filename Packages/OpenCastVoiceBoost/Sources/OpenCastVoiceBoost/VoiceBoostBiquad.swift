import Foundation
import OpenCastVoiceBoostC

struct VoiceBoostBiquad {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    var z1: Double = 0
    var z2: Double = 0

    init(coefficients: OCVBBiquadCoefficients) {
        b0 = coefficients.b0
        b1 = coefficients.b1
        b2 = coefficients.b2
        a1 = coefficients.a1
        a2 = coefficients.a2
    }

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    /// BS.1770 K-weighting stage 1, sourced from the C DSP core so the
    /// offline analyzer and the realtime engine share one derivation.
    static func bs1770PreFilter(sampleRate: Double) -> VoiceBoostBiquad {
        VoiceBoostBiquad(coefficients: OCVBLoudnessPreFilterCoefficients(sampleRate))
    }

    /// BS.1770 K-weighting stage 2 (RLB high-pass), sourced from the C DSP core.
    static func bs1770RLBFilter(sampleRate: Double) -> VoiceBoostBiquad {
        VoiceBoostBiquad(coefficients: OCVBLoudnessRLBFilterCoefficients(sampleRate))
    }
}
