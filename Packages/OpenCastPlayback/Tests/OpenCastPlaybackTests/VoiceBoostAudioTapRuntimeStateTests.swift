@preconcurrency import AVFoundation
import Foundation
import OpenCastVoiceBoost
import Testing
@testable import OpenCastPlayback

/// Covers the tap runtime-state paths that previously had no tests:
/// planar processing, unsupported-format bypass, and
/// prepare -> unprepare -> prepare processor recreation.
struct VoiceBoostAudioTapRuntimeStateTests {
    @Test("Planar processing matches interleaved processing")
    func planarProcessingMatchesInterleavedProcessing() {
        let sampleRate = 48_000.0
        let channelCount = 2
        let blockFrames = 1_024
        let interleaved = FixtureSignal.speechLike(
            amplitude: 0.2,
            sampleRate: sampleRate,
            duration: 1,
            channelCount: channelCount
        )
        let frameCount = interleaved.count / channelCount

        var interleavedState = VoiceBoostAudioTapRuntimeState(configuration: .default)
        interleavedState.prepare(
            maximumFrames: blockFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            isFloat32: true,
            isNonInterleaved: false,
            isSupported: true
        )
        var interleavedOutput = interleaved
        var offset = 0
        while offset < frameCount {
            let blockFrameCount = min(blockFrames, frameCount - offset)
            let processed = AudioBufferListFixture.processInterleaved(
                state: &interleavedState,
                samples: &interleavedOutput,
                channelCount: channelCount,
                frameOffset: offset,
                frameCount: blockFrameCount
            )
            #expect(processed.wasProcessed)
            offset += blockFrameCount
        }

        var planarState = VoiceBoostAudioTapRuntimeState(configuration: .default)
        planarState.prepare(
            maximumFrames: blockFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            isFloat32: true,
            isNonInterleaved: true,
            isSupported: true
        )
        var left = stride(from: 0, to: interleaved.count, by: channelCount).map { interleaved[$0] }
        var right = stride(from: 1, to: interleaved.count, by: channelCount).map { interleaved[$0] }
        offset = 0
        while offset < frameCount {
            let blockFrameCount = min(blockFrames, frameCount - offset)
            let processed = AudioBufferListFixture.processPlanar(
                state: &planarState,
                left: &left,
                right: &right,
                frameOffset: offset,
                frameCount: blockFrameCount
            )
            #expect(processed.wasProcessed)
            offset += blockFrameCount
        }

        let interleavedLeft = stride(from: 0, to: interleavedOutput.count, by: channelCount)
            .map { interleavedOutput[$0] }
        let interleavedRight = stride(from: 1, to: interleavedOutput.count, by: channelCount)
            .map { interleavedOutput[$0] }
        #expect(left == interleavedLeft)
        #expect(right == interleavedRight)
    }

    @Test("Unsupported format leaves audio untouched")
    func unsupportedFormatBypassesUntouched() {
        var state = VoiceBoostAudioTapRuntimeState(configuration: .default)
        state.prepare(
            maximumFrames: 1_024,
            sampleRate: 48_000,
            channelCount: 2,
            isFloat32: false,
            isNonInterleaved: false,
            isSupported: false
        )

        var samples = FixtureSignal.speechLike(
            amplitude: 0.3,
            sampleRate: 48_000,
            duration: 0.05,
            channelCount: 2
        )
        let original = samples
        let processed = AudioBufferListFixture.processInterleaved(
            state: &state,
            samples: &samples,
            channelCount: 2,
            frameOffset: 0,
            frameCount: samples.count / 2
        )

        #expect(processed == .bypassedUnsupported)
        #expect(samples == original)
    }

    @Test("Prepare, unprepare, then prepare again recreates a working processor")
    func prepareUnprepareReprepareProcessesAgain() {
        var state = VoiceBoostAudioTapRuntimeState(configuration: .default)
        var samples = FixtureSignal.speechLike(
            amplitude: 0.2,
            sampleRate: 48_000,
            duration: 0.05,
            channelCount: 1
        )
        let frameCount = samples.count

        state.prepare(
            maximumFrames: frameCount,
            sampleRate: 48_000,
            channelCount: 1,
            isFloat32: true,
            isNonInterleaved: false,
            isSupported: true
        )
        #expect(AudioBufferListFixture.processInterleaved(
            state: &state,
            samples: &samples,
            channelCount: 1,
            frameOffset: 0,
            frameCount: frameCount
        ).wasProcessed)

        state.unprepare()
        var untouched = FixtureSignal.speechLike(
            amplitude: 0.2,
            sampleRate: 48_000,
            duration: 0.05,
            channelCount: 1
        )
        let original = untouched
        #expect(AudioBufferListFixture.processInterleaved(
            state: &state,
            samples: &untouched,
            channelCount: 1,
            frameOffset: 0,
            frameCount: frameCount
        ) == .bypassedUnsupported)
        #expect(untouched == original)

        state.prepare(
            maximumFrames: frameCount,
            sampleRate: 48_000,
            channelCount: 1,
            isFloat32: true,
            isNonInterleaved: false,
            isSupported: true
        )
        #expect(AudioBufferListFixture.processInterleaved(
            state: &state,
            samples: &untouched,
            channelCount: 1,
            frameOffset: 0,
            frameCount: frameCount
        ).wasProcessed)
    }

    @Test("Planar processing survives frame counts beyond the prepared capacity")
    func planarSurvivesFrameCountBeyondPreparedCapacity() {
        // The planar path hands the tap's channel pointers straight
        // to the C engine, so an over-capacity callback processes in place
        // exactly like the interleaved path always has (per-buffer byte
        // sizes are still validated); only the transition blend degrades to
        // unblended processing when the dry scratch cannot hold the
        // callback. The old marshal bypassed these because its
        // scratch was fixed at prepare time.
        var state = VoiceBoostAudioTapRuntimeState(configuration: .default)
        state.prepare(
            maximumFrames: 256,
            sampleRate: 48_000,
            channelCount: 2,
            isFloat32: true,
            isNonInterleaved: true,
            isSupported: true
        )

        var left = [Float](repeating: 0.1, count: 512)
        var right = [Float](repeating: 0.1, count: 512)
        let processed = AudioBufferListFixture.processPlanar(
            state: &state,
            left: &left,
            right: &right,
            frameOffset: 0,
            frameCount: 512
        )

        #expect(processed.wasProcessed)
        for sample in left + right {
            #expect(sample.isFinite)
        }
    }
}
