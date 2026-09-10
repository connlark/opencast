import Foundation
import Testing
@testable import OpenCastVoiceBoost

struct VoiceBoostContinuationTests {
    @Test(arguments: [44_100.0, 48_000.0], [1, 2])
    func handoffPreservesVariableSpeechLoudness(sampleRate: Double, channels: Int) {
        let source = VoiceBoostFixtureGenerator.alternatingSpeechLike(
            quietAmplitude: 0.05, loudAmplitude: 0.3, segmentDuration: 2.3,
            sampleRate: sampleRate, duration: 72, channelCount: channels
        )
        let reference = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channels)
        var expected = source
        process(&expected, with: reference, channels: channels)

        // Both an early handoff and a wrapped 60-second measurement ring;
        // neither falls on a completed 100 ms measurement boundary.
        for handoff in [17.037, 63.713] {
            let boundary = Int(handoff * sampleRate) * channels
            var before = Array(source[..<boundary])
            let outgoing = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channels)
            process(&before, with: outgoing, channels: channels)
            let continuation = outgoing.continuationState
            #expect(continuation.integratedBlockCount > 20)

            let incoming = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channels)
            incoming.apply(continuationState: continuation)
            var after = Array(source[boundary...])
            process(&after, with: incoming, channels: channels)

            let hop = Int(sampleRate * 0.1) * channels
            let window = Int(sampleRate * 0.4) * channels
            for start in stride(from: hop, through: after.count - window, by: hop) {
                let actualRMS = VoiceBoostFixtureGenerator.rms(Array(after[start..<(start + window)]))
                let expectedRMS = VoiceBoostFixtureGenerator.rms(Array(expected[(boundary + start)..<(boundary + start + window)]))
                #expect(abs(20 * log10(actualRMS / expectedRMS)) < 1,
                        "handoff=\(handoff), sample offset=\(start)")
            }
            #expect(after.allSatisfy { $0.isFinite })
            #expect(incoming.metrics.safetyClampCount == 0)
        }
    }

    @Test(arguments: [44_100.0, 48_000.0], [1, 2])
    func continuationClearsAudioAndSurvivesLouderReplacement(sampleRate: Double, channels: Int) {
        let outgoing = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 2)
        var warmup = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.05, sampleRate: 48_000, duration: 8, channelCount: 2
        )
        process(&warmup, with: outgoing, channels: 2)
        let state = outgoing.continuationState
        let incoming = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channels)
        incoming.apply(continuationState: state)
        #expect(incoming.continuationState.integratedBlockCount == state.integratedBlockCount)
        #expect(incoming.metrics.currentAutoGainDB == state.controlSnapshot.currentAutoGainDB)

        var silence = Array(repeating: Float.zero, count: Int(sampleRate * 0.2) * channels)
        process(&silence, with: incoming, channels: channels)
        #expect(silence.allSatisfy { $0 == 0 })

        var louder = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.8, sampleRate: sampleRate, duration: 4, channelCount: channels
        )
        process(&louder, with: incoming, channels: channels)
        let truePeak = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
            louder, channelCount: channels, sampleRate: sampleRate
        )
        #expect(truePeak <= VoiceBoostConfiguration.default.truePeakCeilingDBTP + 0.1)
        #expect(incoming.metrics.safetyClampCount == 0)
        #expect(louder.allSatisfy { $0.isFinite })

        incoming.reset()
        #expect(incoming.continuationState.integratedBlockCount == 0)
        #expect(incoming.metrics.currentAutoGainDB == 0)
    }

    @Test
    func malformedHistoryCannotInstallInvalidRingIndicesOrNonfiniteEnergy() {
        let processor = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 1)
        var state = processor.continuationState
        state.cState.integratedCount = 601
        processor.apply(continuationState: state)
        #expect(processor.continuationState.integratedBlockCount == 0)
        state.cState.integratedCount = 1
        state.cState.inputSubBlocks.0 = .nan
        processor.apply(continuationState: state)
        #expect(processor.continuationState.integratedBlockCount == 0)
    }

    private func process(_ audio: inout [Float], with processor: VoiceBoostProcessor, channels: Int) {
        let blocks = [127, 1_024, 333, 2_048]
        var offset = 0
        var iteration = 0
        while offset < audio.count {
            let frames = min(blocks[iteration % blocks.count], (audio.count - offset) / channels)
            audio.withUnsafeMutableBufferPointer {
                processor.processInterleavedFloat32(
                    UnsafeMutableBufferPointer(start: $0.baseAddress! + offset, count: frames * channels),
                    frameCount: frames
                )
            }
            offset += frames * channels
            iteration += 1
        }
    }
}
