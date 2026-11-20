import Foundation
import Testing
@testable import OpenCastVoiceBoost

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
        // Convergence is only fair when the target is reachable within the gain
        // bounds, with headroom for the wet chain's loudness loss.
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
        // 40 s stays inside the engine's 60 s rolling window, so both meters
        // integrate the same history; alternating levels exercise the relative gate.
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

        // The meters share the sub-block grid and coefficients, so they agree
        // almost exactly.
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

        // The rolling output estimate is gated on the input, so it differs
        // slightly from a full offline pass.
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

        // Windows straddling the speech-to-silence boundary still pass the
        // gate, so flush them first: the check is for drift in sustained silence.
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
        #expect(abs(afterResume.currentAutoGainDB - beforeSilence.currentAutoGainDB) <= 1.0)
    }
}
