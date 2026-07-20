import Foundation
import Testing
@testable import OpenCastVoiceBoost

/// Pass 4 dynamics coverage: the configurable soft-knee compressor's static
/// curve (D8) and the adaptation control snapshot that survives processor
/// recreation (I3).
struct VoiceBoostDynamicsTests {
    private let sampleRate = 48_000.0

    /// Equal attack/release turn the envelope EMA into a plain low-pass of
    /// the squared signal, so a steady sine settles the envelope at exactly
    /// its mean square and the static curve can be measured tightly.
    private func curveConfiguration(
        thresholdDB: Double = -20,
        ratio: Double = 2,
        kneeWidthDB: Double = 6,
        maximumReductionDB: Double = 20
    ) -> VoiceBoostConfiguration {
        VoiceBoostConfiguration(
            isEnabled: true,
            usesAdaptiveGain: false,
            usesEqualization: false,
            usesCompression: true,
            compressorThresholdDB: thresholdDB,
            compressorRatio: ratio,
            compressorKneeWidthDB: kneeWidthDB,
            compressorAttackSeconds: 0.020,
            compressorReleaseSeconds: 0.020,
            compressorMaximumReductionDB: maximumReductionDB
        )
    }

    private func expectedReductionDB(
        envelopeDB: Double,
        thresholdDB: Double,
        ratio: Double,
        kneeWidthDB: Double,
        maximumReductionDB: Double
    ) -> Double {
        let slope = 1 - 1 / ratio
        let overDB = envelopeDB - thresholdDB
        let halfKnee = kneeWidthDB / 2
        let reduction: Double = if overDB > halfKnee {
            slope * overDB
        } else if overDB > -halfKnee {
            slope * (overDB + halfKnee) * (overDB + halfKnee) / (2 * kneeWidthDB)
        } else {
            0
        }
        return min(reduction, maximumReductionDB)
    }

    /// Processes a steady sine whose envelope lands at `envelopeDB` and
    /// returns the measured steady-state gain reduction in dB.
    private func measuredReductionDB(
        envelopeDB: Double,
        configuration: VoiceBoostConfiguration
    ) -> Double {
        // Envelope of a sine at equal attack/release is its mean square:
        // envelopeDB = 20 log10(amplitude) - 3.0103.
        let amplitude = pow(10, (envelopeDB + 10 * log10(2.0)) / 20)
        var buffer = VoiceBoostFixtureGenerator.sine(
            frequency: 997,
            amplitude: amplitude,
            sampleRate: sampleRate,
            duration: 1.5,
            channelCount: 1
        )
        let input = buffer
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: configuration
        )
        VoiceBoostFixtureGenerator.processInBlocks(&buffer, processor: processor, channelCount: 1)

        let tailStart = buffer.count - Int(sampleRate * 0.25)
        let inputRMS = VoiceBoostFixtureGenerator.rms(Array(input[tailStart...]))
        let outputRMS = VoiceBoostFixtureGenerator.rms(Array(buffer[tailStart...]))
        return 20 * log10(inputRMS / outputRMS)
    }

    @Test(
        "Static gain curve matches the piecewise soft-knee definition",
        arguments: [-30.0, -24.0, -21.5, -20.0, -18.0, -16.0, -12.0, -8.0]
    )
    func staticCurveMatchesSoftKneeDefinition(envelopeDB: Double) {
        let configuration = curveConfiguration()
        let expected = expectedReductionDB(
            envelopeDB: envelopeDB,
            thresholdDB: configuration.compressorThresholdDB,
            ratio: configuration.compressorRatio,
            kneeWidthDB: configuration.compressorKneeWidthDB,
            maximumReductionDB: configuration.compressorMaximumReductionDB
        )
        let measured = measuredReductionDB(envelopeDB: envelopeDB, configuration: configuration)
        #expect(abs(measured - expected) < 0.15)
    }

    @Test("The maximum-reduction cap is enforced")
    func maximumReductionCapIsEnforced() {
        let configuration = curveConfiguration(maximumReductionDB: 3)
        let measured = measuredReductionDB(envelopeDB: -8, configuration: configuration)
        // Uncapped the ratio line would demand 6 dB here.
        #expect(abs(measured - 3) < 0.15)
    }

    @Test("A zero-width knee reproduces the hard-knee curve")
    func zeroWidthKneeIsHardKnee(
    ) {
        let configuration = curveConfiguration(kneeWidthDB: 0)
        let below = measuredReductionDB(envelopeDB: -21, configuration: configuration)
        let above = measuredReductionDB(envelopeDB: -14, configuration: configuration)
        #expect(abs(below) < 0.05)
        #expect(abs(above - 3) < 0.15)
    }

    @Test("Invalid compressor parameters sanitize to the documented defaults")
    func invalidCompressorParametersSanitizeToDefaults() {
        var garbage = VoiceBoostConfiguration.default
        garbage.compressorThresholdDB = .nan
        garbage.compressorRatio = 0.2
        garbage.compressorKneeWidthDB = -5
        garbage.compressorAttackSeconds = .infinity
        garbage.compressorReleaseSeconds = 0
        garbage.compressorMaximumReductionDB = -1

        var garbageBuffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.4,
            sampleRate: sampleRate,
            duration: 2,
            channelCount: 1
        )
        var defaultBuffer = garbageBuffer
        let garbageProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: garbage
        )
        let defaultProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: .default
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &garbageBuffer,
            processor: garbageProcessor,
            channelCount: 1
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &defaultBuffer,
            processor: defaultProcessor,
            channelCount: 1
        )
        #expect(garbageBuffer == defaultBuffer)
    }

    /// Pins the spec's "threshold after loudness gain" wording: a sine far
    /// below the threshold at the input only compresses because auto gain
    /// lifts it past the threshold first.
    @Test("The compressor envelope is measured post-auto-gain")
    func compressorEnvelopeIsPostAutoGain() {
        // Envelope -26 dB at the input, threshold -20: pre-gain metering
        // would never compress. Adaptive gain converges to +12 here.
        let amplitude = pow(10, (-26.0 + 10 * log10(2.0)) / 20)
        var configuration = curveConfiguration()
        configuration.usesAdaptiveGain = true
        configuration.targetLUFS = -13
        configuration.maximumPositiveGainDB = 12

        var buffer = VoiceBoostFixtureGenerator.sine(
            frequency: 200,
            amplitude: amplitude,
            sampleRate: sampleRate,
            duration: 15,
            channelCount: 1
        )
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: configuration
        )
        VoiceBoostFixtureGenerator.processInBlocks(&buffer, processor: processor, channelCount: 1)

        let metrics = processor.metrics
        #expect(metrics.currentAutoGainDB > 8)
        #expect(metrics.currentCompressorReductionDB > 0.5)

        var withoutGain = VoiceBoostFixtureGenerator.sine(
            frequency: 200,
            amplitude: amplitude,
            sampleRate: sampleRate,
            duration: 15,
            channelCount: 1
        )
        let staticProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: curveConfiguration()
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &withoutGain,
            processor: staticProcessor,
            channelCount: 1
        )
        #expect(staticProcessor.metrics.currentCompressorReductionDB == 0)
    }

    // MARK: - Control snapshot (I3)

    /// Converges gain on a quiet fixture and returns the processor.
    private func convergedProcessor(
        sampleRate: Double,
        seconds: Double = 20
    ) -> VoiceBoostProcessor {
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: .default
        )
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.05,
            sampleRate: sampleRate,
            duration: seconds,
            channelCount: 1
        )
        VoiceBoostFixtureGenerator.processInBlocks(&buffer, processor: processor, channelCount: 1)
        return processor
    }

    @Test("A control snapshot restores gain and confidence across recreation and sample rates")
    func controlSnapshotRestoresAcrossRecreation() {
        let source = convergedProcessor(sampleRate: 48_000)
        let convergedGain = source.metrics.currentAutoGainDB
        #expect(convergedGain > 5)

        let snapshot = source.controlSnapshot
        #expect(abs(snapshot.currentAutoGainDB - convergedGain) < 1e-12)
        #expect(snapshot.gatedBlockCount >= 20)

        // Different sample rate: the snapshot is dB/energy-domain, so it
        // must carry unchanged.
        let restored = VoiceBoostProcessor(
            sampleRate: 44_100,
            channelCount: 1,
            configuration: .default
        )
        restored.apply(controlSnapshot: snapshot)
        #expect(abs(restored.metrics.currentAutoGainDB - convergedGain) < 1e-12)

        // The low-confidence cap must not re-clamp: gain stays high through
        // the first post-restore seconds where a fresh processor would sit
        // at the +3 dB cap.
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.05,
            sampleRate: 44_100,
            duration: 2,
            channelCount: 1
        )
        VoiceBoostFixtureGenerator.processInBlocks(&buffer, processor: restored, channelCount: 1)
        #expect(restored.metrics.currentAutoGainDB > 4)

        let fresh = VoiceBoostProcessor(
            sampleRate: 44_100,
            channelCount: 1,
            configuration: .default
        )
        var freshBuffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.05,
            sampleRate: 44_100,
            duration: 2,
            channelCount: 1
        )
        VoiceBoostFixtureGenerator.processInBlocks(&freshBuffer, processor: fresh, channelCount: 1)
        #expect(fresh.metrics.currentAutoGainDB < 3.5)
    }

    @Test("Reset plus snapshot re-seed keeps gain steady across a seek")
    func resetWithReseedKeepsGainSteady() {
        let processor = convergedProcessor(sampleRate: 48_000)
        let convergedGain = processor.metrics.currentAutoGainDB
        #expect(convergedGain > 5)

        // Seek policy: measurement and signal state reset, control re-seeded.
        let snapshot = processor.controlSnapshot
        processor.reset()
        processor.apply(controlSnapshot: snapshot)
        #expect(abs(processor.metrics.currentAutoGainDB - convergedGain) < 1e-12)

        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.05,
            sampleRate: 48_000,
            duration: 3,
            channelCount: 1
        )
        VoiceBoostFixtureGenerator.processInBlocks(&buffer, processor: processor, channelCount: 1)
        #expect(abs(processor.metrics.currentAutoGainDB - convergedGain) < 1.5)
    }

    @Test("Applying a hostile snapshot clamps or ignores every field")
    func hostileSnapshotIsSanitized() {
        let processor = VoiceBoostProcessor(
            sampleRate: 48_000,
            channelCount: 1,
            configuration: .default
        )
        var hostile = processor.controlSnapshot
        hostile.cSnapshot.desiredGainDB = .infinity
        hostile.cSnapshot.currentAutoGainDB = 400
        hostile.cSnapshot.hasIntegratedInput = 1
        hostile.cSnapshot.integratedInputEnergy = -1
        hostile.cSnapshot.hasChainLoss = 1
        hostile.cSnapshot.chainLossDB = 80
        hostile.cSnapshot.gatedBlockCount = -7
        processor.apply(controlSnapshot: hostile)

        let applied = processor.controlSnapshot
        #expect(applied.desiredGainDB == 0)
        #expect(applied.currentAutoGainDB == VoiceBoostConfiguration.default.maximumPositiveGainDB)
        #expect(applied.integratedInputLUFS == nil)
        #expect(applied.chainLossDB == 4)
        #expect(applied.gatedBlockCount == 0)
    }
}
