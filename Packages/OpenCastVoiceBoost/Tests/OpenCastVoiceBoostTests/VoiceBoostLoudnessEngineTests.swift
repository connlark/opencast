import Foundation
import Testing
@testable import OpenCastVoiceBoost

/// Pass 2 requirements for the gated loudness engine: output convergence to
/// target (flipped from the Pass-1 `withKnownIssue` spec gap to a hard
/// requirement), runtime/offline agreement on one fixture, honest K-weighted
/// output metering (D7), and silence robustness (never chase silence).
struct VoiceBoostLoudnessEngineTests {
    @Test("Output integrated LUFS converges to targetLUFS within ±1 LU")
    func outputIntegratedLoudnessConvergesToTarget() throws {
        let sampleRate = 48_000.0
        let channelCount = 2
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.2,
            sampleRate: sampleRate,
            duration: 60,
            channelCount: channelCount
        )
        let inputAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            buffer,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let inputLUFS = try #require(inputAnalysis.integratedLUFS)
        let configuration = VoiceBoostConfiguration.default
        // The target must be reachable within the configured gain bounds with
        // headroom for the measured wet-chain loudness loss (EQ + compressor)
        // for convergence to be a fair expectation.
        #expect(configuration.targetLUFS - inputLUFS <= configuration.maximumPositiveGainDB - 3)

        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: channelCount
        )

        let steadyStateOffset = Int(sampleRate * 10) * channelCount
        let steadyStateTail = Array(buffer[steadyStateOffset...])
        let outputAnalysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            steadyStateTail,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let outputLUFS = try #require(outputAnalysis.integratedLUFS)

        #expect(abs(outputLUFS - configuration.targetLUFS) <= 1.0)
    }

    @Test(
        "Runtime integrated input agrees with the offline analyzer",
        arguments: [(48_000.0, 2), (44_100.0, 1)]
    )
    func runtimeIntegratedInputAgreesWithOfflineAnalyzer(sampleRate: Double, channelCount: Int) throws {
        // 40 s keeps the fixture inside the engine's 60 s rolling window so
        // both meters integrate the same complete history; the alternating
        // levels exercise the relative gate.
        var buffer = VoiceBoostFixtureGenerator.alternatingSpeechLike(
            quietAmplitude: 0.04,
            loudAmplitude: 0.3,
            segmentDuration: 2.0,
            sampleRate: sampleRate,
            duration: 40,
            channelCount: channelCount
        )
        let offline = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
            buffer,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let offlineIntegrated = try #require(offline.integratedLUFS)

        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: VoiceBoostConfiguration(isEnabled: false)
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: channelCount
        )
        let runtimeIntegrated = try #require(processor.metrics.integratedInputLUFS)

        // Plan target is <= 0.3 LU; the shared grid and coefficients keep the
        // two meters numerically identical in practice.
        #expect(abs(runtimeIntegrated - offlineIntegrated) <= 0.05)
    }

    @Test("Runtime output loudness is K-weighted and agrees with the offline analyzer")
    func runtimeOutputLoudnessAgreesWithOfflineAnalyzer() throws {
        let sampleRate = 48_000.0
        let channelCount = 2
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.2,
            sampleRate: sampleRate,
            duration: 30,
            channelCount: channelCount
        )
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: channelCount
        )

        let runtimeOutput = try #require(processor.metrics.estimatedOutputLUFS)
        let offlineOutput = try #require(
            VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
                buffer,
                sampleRate: sampleRate,
                channelCount: channelCount
            ).integratedLUFS
        )

        // The rolling gated output estimate inserts on the input gate, so it
        // is not bit-identical to a full offline pass; it must still land
        // well inside the honest-metering tolerance.
        #expect(abs(runtimeOutput - offlineOutput) <= 0.3)
    }

    @Test("Long silence freezes the integrated estimate and auto-gain")
    func longSilenceDoesNotDivergeEstimateOrGain() throws {
        let sampleRate = 48_000.0
        let channelCount = 2
        let speech = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.2,
            sampleRate: sampleRate,
            duration: 15,
            channelCount: channelCount
        )
        let resumedSpeech = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.2,
            sampleRate: sampleRate,
            duration: 5,
            channelCount: channelCount
        )
        let processor = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channelCount)

        var speechBuffer = speech
        VoiceBoostFixtureGenerator.processInBlocks(
            &speechBuffer,
            processor: processor,
            channelCount: channelCount
        )

        // The momentary windows straddling the speech-to-silence boundary
        // legitimately pass the gate (they contain speech energy), so flush
        // them before snapshotting: divergence means drift during *sustained*
        // silence, not the standard's boundary-block behavior.
        var boundarySilence = VoiceBoostFixtureGenerator.silence(
            sampleRate: sampleRate,
            duration: 2,
            channelCount: channelCount
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &boundarySilence,
            processor: processor,
            channelCount: channelCount
        )
        let beforeSilence = processor.metrics
        let integratedBefore = try #require(beforeSilence.integratedInputLUFS)

        var silenceBuffer = VoiceBoostFixtureGenerator.silence(
            sampleRate: sampleRate,
            duration: 28,
            channelCount: channelCount
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &silenceBuffer,
            processor: processor,
            channelCount: channelCount
        )
        let afterSilence = processor.metrics
        let integratedAfter = try #require(afterSilence.integratedInputLUFS)

        #expect(abs(integratedAfter - integratedBefore) <= 0.0001)
        #expect(abs(afterSilence.currentAutoGainDB - beforeSilence.currentAutoGainDB) <= 0.01)

        var resumeBuffer = resumedSpeech
        VoiceBoostFixtureGenerator.processInBlocks(
            &resumeBuffer,
            processor: processor,
            channelCount: channelCount
        )
        let afterResume = processor.metrics
        // Resuming the same program must not require re-convergence.
        #expect(abs(afterResume.currentAutoGainDB - beforeSilence.currentAutoGainDB) <= 1.0)
    }
}
