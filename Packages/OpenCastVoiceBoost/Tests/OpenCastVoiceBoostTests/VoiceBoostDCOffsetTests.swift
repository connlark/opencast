import Foundation
import Testing
@testable import OpenCastVoiceBoost

/// Pins the Pass 4 D11 decision: DC protection comes from the 70 Hz HPF in
/// the default (EQ-on) chain, and EQ-off configurations are documented as
/// unprotected — an always-on DC blocker in the signal path would break the
/// limiterOnly null-transparency invariant, which requires passing the
/// waveform (DC included) bit-identically.
struct VoiceBoostDCOffsetTests {
    private let sampleRate = 48_000.0
    private let dcOffset: Float = 0.05

    private func speechWithDC(_ offset: Float) -> [Float] {
        VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.3,
            sampleRate: sampleRate,
            duration: 8,
            channelCount: 1
        ).map { $0 + offset }
    }

    @Test("The default chain scrubs DC before the envelope and the output")
    func defaultChainScrubsDC() {
        var clean = speechWithDC(0)
        var offset = speechWithDC(dcOffset)

        let cleanProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: .default
        )
        let offsetProcessor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: .default
        )
        VoiceBoostFixtureGenerator.processInBlocks(&clean, processor: cleanProcessor, channelCount: 1)
        VoiceBoostFixtureGenerator.processInBlocks(&offset, processor: offsetProcessor, channelCount: 1)

        let tailStart = offset.count / 2
        let outputDC = offset[tailStart...].reduce(0.0) { $0 + Double($1) }
            / Double(offset.count - tailStart)
        #expect(abs(outputDC) < 0.002)

        // The compressor envelope must not see the offset: reduction
        // matches the clean run.
        let cleanReduction = cleanProcessor.metrics.currentCompressorReductionDB
        let offsetReduction = offsetProcessor.metrics.currentCompressorReductionDB
        #expect(abs(cleanReduction - offsetReduction) < 0.1)
    }

    @Test("limiterOnly passes DC bit-identically - null transparency includes the offset")
    func limiterOnlyPassesDCBitIdentically() {
        var buffer = speechWithDC(dcOffset)
        let original = buffer
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )
        VoiceBoostFixtureGenerator.processInBlocks(&buffer, processor: processor, channelCount: 1)

        let latencyFrames = processor.metrics.latencyFrames
        #expect(buffer[..<latencyFrames].allSatisfy { $0 == 0 })
        #expect(
            Array(buffer[latencyFrames...])
                == Array(original[..<(original.count - latencyFrames)])
        )
    }
}
