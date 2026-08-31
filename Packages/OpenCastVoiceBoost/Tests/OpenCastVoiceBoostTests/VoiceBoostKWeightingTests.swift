import Foundation
import Testing
import OpenCastVoiceBoostC
@testable import OpenCastVoiceBoost

/// The K-weighting coefficients are derived analytically in C
/// for any sample rate and are the single source of truth for the realtime
/// engine and the Swift offline analyzer.
struct VoiceBoostKWeightingTests {
    /// ITU-R BS.1770 reference tables previously hardcoded in both the C DSP
    /// core and `VoiceBoostBiquad`; kept here as the equivalence oracle.
    private static let referenceTables: [(stage: String, sampleRate: Double, coefficients: [Double])] = [
        ("pre", 48_000, [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]),
        ("pre", 44_100, [1.530841230050347, -2.650979995154729, 1.169079079921906, -1.663655113256020, 0.712595428073225]),
        ("rlb", 48_000, [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]),
        ("rlb", 44_100, [1.0, -2.0, 1.0, -1.989169673629796, 0.989199035787039])
    ]

    @Test("Analytic derivation reproduces the BS.1770 reference tables")
    func analyticDerivationMatchesReferenceTables() {
        for table in Self.referenceTables {
            let derived = table.stage == "pre"
                ? OCVBLoudnessPreFilterCoefficients(table.sampleRate)
                : OCVBLoudnessRLBFilterCoefficients(table.sampleRate)
            let coefficients = [derived.b0, derived.b1, derived.b2, derived.a1, derived.a2]
            for (index, reference) in table.coefficients.enumerated() {
                #expect(
                    abs(coefficients[index] - reference) <= 1e-6,
                    "\(table.stage)@\(table.sampleRate) coefficient \(index) drifted from the reference table"
                )
            }
        }
    }

    @Test(
        "K-weighting response is sane at non-table sample rates",
        arguments: [22_050.0, 24_000.0, 32_000.0, 44_100.0, 48_000.0, 96_000.0]
    )
    func responseIsSaneAcrossSampleRates(sampleRate: Double) {
        // The loudness offset convention (-0.691) makes a 997 Hz tone read
        // "level-accurate", which requires the cascade to sit at +0.691 dB
        // there; the shelf plateau is ~+4 dB.
        let at997 = Self.cascadeResponseDB(frequency: 997, sampleRate: sampleRate)
        #expect(abs(at997 - 0.691) <= 0.05)

        let shelf = Self.cascadeResponseDB(frequency: 0.4 * sampleRate, sampleRate: sampleRate)
        #expect(shelf >= 3.5 && shelf <= 4.5)

        let lowEnd = Self.cascadeResponseDB(frequency: 100, sampleRate: sampleRate)
        #expect(lowEnd >= -1.3 && lowEnd <= -0.9)
    }

    @Test("Swift analyzer consumes the C-derived coefficients")
    func swiftAnalyzerUsesCDerivedCoefficients() {
        for sampleRate in [32_000.0, 44_100.0, 48_000.0] {
            let pre = OCVBLoudnessPreFilterCoefficients(sampleRate)
            let swiftPre = VoiceBoostBiquad.bs1770PreFilter(sampleRate: sampleRate)
            #expect(swiftPre.b0 == pre.b0 && swiftPre.a2 == pre.a2)

            let rlb = OCVBLoudnessRLBFilterCoefficients(sampleRate)
            let swiftRLB = VoiceBoostBiquad.bs1770RLBFilter(sampleRate: sampleRate)
            #expect(swiftRLB.a1 == rlb.a1 && swiftRLB.a2 == rlb.a2)
        }
    }

    private static func cascadeResponseDB(frequency: Double, sampleRate: Double) -> Double {
        let pre = OCVBLoudnessPreFilterCoefficients(sampleRate)
        let rlb = OCVBLoudnessRLBFilterCoefficients(sampleRate)
        let omega = 2 * Double.pi * frequency / sampleRate

        func magnitude(_ coefficients: OCVBBiquadCoefficients) -> Double {
            // |H(e^jw)| for b0 + b1 z^-1 + b2 z^-2 over 1 + a1 z^-1 + a2 z^-2.
            func power(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
                let real = c0 + c1 * cos(omega) + c2 * cos(2 * omega)
                let imaginary = -(c1 * sin(omega) + c2 * sin(2 * omega))
                return real * real + imaginary * imaginary
            }
            let numerator = power(coefficients.b0, coefficients.b1, coefficients.b2)
            let denominator = power(1, coefficients.a1, coefficients.a2)
            return sqrt(numerator / denominator)
        }

        return 20 * log10(magnitude(pre) * magnitude(rlb))
    }
}
