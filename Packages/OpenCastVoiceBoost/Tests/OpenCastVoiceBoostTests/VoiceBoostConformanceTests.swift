import Foundation
import Testing
@testable import OpenCastVoiceBoost

struct VoiceBoostConformanceTests {
    @Test("dB and loudness conversions handle zero and round-trip ordinary values")
    func conversionsAreSafe() {
        let zeroDB = VoiceBoostLevel.decibels(amplitude: 0)
        #expect(zeroDB.isInfinite)
        #expect(zeroDB < 0)
        #expect(abs(VoiceBoostLevel.linearAmplitude(decibels: -6.020_599_913) - 0.5) < 0.000_000_001)

        let meanSquare = VoiceBoostLevel.meanSquare(loudnessLUFS: -14)
        #expect(abs(VoiceBoostLevel.loudness(meanSquare: meanSquare) - -14) < 0.000_000_001)
    }

    @Test("400 ms momentary window tracks a 6 dB amplitude change")
    func momentaryWindowSanity() {
        let low = VoiceBoostFixtureGenerator.sine(
            frequency: 1_000,
            amplitude: 0.05,
            sampleRate: 48_000,
            duration: 0.6,
            channelCount: 1
        )
        let high = VoiceBoostFixtureGenerator.sine(
            frequency: 1_000,
            amplitude: 0.10,
            sampleRate: 48_000,
            duration: 0.6,
            channelCount: 1
        )

        let lowAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            low,
            sampleRate: 48_000,
            channelCount: 1
        )
        let highAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            high,
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(lowAnalysis.momentaryLUFS.count == 3)
        #expect(highAnalysis.momentaryLUFS.count == 3)
        #expect(abs((highAnalysis.momentaryLUFS[1] - lowAnalysis.momentaryLUFS[1]) - 6.0206) < 0.05)
    }

    @Test("3 second short-term window tracks a 6 dB amplitude change")
    func shortTermWindowSanity() {
        let low = VoiceBoostFixtureGenerator.sine(
            frequency: 1_000,
            amplitude: 0.05,
            sampleRate: 48_000,
            duration: 3.2,
            channelCount: 1
        )
        let high = VoiceBoostFixtureGenerator.sine(
            frequency: 1_000,
            amplitude: 0.10,
            sampleRate: 48_000,
            duration: 3.2,
            channelCount: 1
        )

        let lowAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            low,
            sampleRate: 48_000,
            channelCount: 1
        )
        let highAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            high,
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(lowAnalysis.shortTermLUFS.count == 3)
        #expect(highAnalysis.shortTermLUFS.count == 3)
        #expect(abs((highAnalysis.shortTermLUFS[1] - lowAnalysis.shortTermLUFS[1]) - 6.0206) < 0.05)
    }

    @Test("Absolute gate rejects silence and very low-level blocks")
    func absoluteGateRejectsSilenceAndLowLevelBlocks() {
        let silence = VoiceBoostFixtureGenerator.silence(
            sampleRate: 48_000,
            duration: 1,
            channelCount: 1
        )
        let lowLevel = VoiceBoostFixtureGenerator.sine(
            frequency: 1_000,
            amplitude: 0.000_01,
            sampleRate: 48_000,
            duration: 1,
            channelCount: 1
        )

        let silenceAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            silence,
            sampleRate: 48_000,
            channelCount: 1
        )
        let lowLevelAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            lowLevel,
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(silenceAnalysis.integratedLUFS == nil)
        #expect(lowLevelAnalysis.integratedLUFS == nil)
    }

    @Test("Relative gate ignores foreground-separated silence")
    func relativeGateIgnoresSilence() {
        let foreground = VoiceBoostFixtureGenerator.sine(
            frequency: 1_000,
            amplitude: 0.10,
            sampleRate: 48_000,
            duration: 3,
            channelCount: 1
        )
        let silence = VoiceBoostFixtureGenerator.silence(
            sampleRate: 48_000,
            duration: 3,
            channelCount: 1
        )
        let combined = foreground + silence

        let foregroundAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            foreground,
            sampleRate: 48_000,
            channelCount: 1
        )
        let combinedAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            combined,
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(foregroundAnalysis.integratedLUFS != nil)
        #expect(combinedAnalysis.integratedLUFS != nil)
        #expect(abs((combinedAnalysis.integratedLUFS ?? 0) - (foregroundAnalysis.integratedLUFS ?? 0)) < 0.5)
    }

    @Test("K-weighting filter is deterministic")
    func kWeightingIsDeterministic() {
        var impulse = [Float](repeating: 0, count: 32)
        impulse[0] = 1

        let first = VoiceBoostLoudnessAnalyzer.kWeightedInterleavedFloat32(
            impulse,
            sampleRate: 48_000,
            channelCount: 1
        )
        let second = VoiceBoostLoudnessAnalyzer.kWeightedInterleavedFloat32(
            impulse,
            sampleRate: 48_000,
            channelCount: 1
        )

        #expect(first == second)
        #expect(abs(first[0] - 1.535_124_859_586_97) < 0.000_000_001)
        #expect(first.dropFirst().contains { abs($0) > 0.001 })
    }

    @Test("True peak estimator distinguishes sample peak from inter-sample peak")
    func truePeakExceedsSamplePeakForStressFixture() {
        let buffer = intersampleStressFixture(amplitude: 0.85, repetitions: 512)
        let samplePeak = VoiceBoostTruePeakAnalyzer.samplePeakDBFS(buffer)
        let truePeak = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
            buffer,
            channelCount: 1,
            oversampleFactor: 4
        )

        #expect(truePeak > samplePeak + 0.6)
    }

    @Test("Limiter catches generated inter-sample peak stress fixture")
    func limiterCatchesIntersamplePeakStressFixture() {
        var buffer = intersampleStressFixture(amplitude: 0.85, repetitions: 512)
        let processor = VoiceBoostProcessor(
            sampleRate: 48_000,
            channelCount: 1,
            configuration: VoiceBoostConfiguration(
                truePeakCeilingDBTP: -1,
                maximumPositiveGainDB: 0,
                maximumNegativeGainDB: 0
            )
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 1,
            blockSize: 256
        )

        let truePeak = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
            buffer,
            channelCount: 1,
            oversampleFactor: 4
        )
        #expect(truePeak <= -0.9)
    }

    @Test("Reset clears loudness and limiter state")
    func resetClearsConformanceState() {
        var buffer = intersampleStressFixture(amplitude: 0.95, repetitions: 512)
        let processor = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 1)
        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 1,
            blockSize: 256
        )
        #expect(processor.metrics.outputTruePeakDBTP != nil)

        processor.reset()

        var silence = VoiceBoostFixtureGenerator.silence(
            sampleRate: 48_000,
            duration: 0.4,
            channelCount: 1
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &silence,
            processor: processor,
            channelCount: 1,
            blockSize: 256
        )

        #expect(processor.metrics.estimatedInputLUFS == nil)
        #expect(processor.metrics.outputTruePeakDBTP == nil)
        #expect(VoiceBoostFixtureGenerator.maxAbs(silence) == 0)
    }

    private func intersampleStressFixture(amplitude: Float, repetitions: Int) -> [Float] {
        let pattern: [Float] = [
            0,
            amplitude,
            amplitude,
            0,
            0,
            -amplitude,
            -amplitude,
            0
        ]
        return Array(repeating: pattern, count: repetitions).flatMap { $0 }
    }
}
