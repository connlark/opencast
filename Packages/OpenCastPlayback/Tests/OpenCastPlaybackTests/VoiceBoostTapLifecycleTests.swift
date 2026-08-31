@preconcurrency import AVFoundation
import Foundation
import OpenCastVoiceBoost
import Testing
@testable import OpenCastPlayback

/// Lifecycle coverage: adaptation carryover across re-prepare,
/// the seek re-seed policy, drain interruptions (teardown mid-drain), the
/// enable-from-never-engaged path, and the split bypass counters.
struct VoiceBoostTapLifecycleTests {
    private let sampleRate = 48_000.0
    private let blockFrames = 1_024

    private func preparedState(
        configuration: VoiceBoostConfiguration = .default,
        sampleRate: Double = 48_000,
        channelCount: Int = 1
    ) -> VoiceBoostAudioTapRuntimeState {
        var state = VoiceBoostAudioTapRuntimeState(configuration: configuration)
        state.prepare(
            maximumFrames: blockFrames,
            sampleRate: sampleRate,
            channelCount: channelCount,
            isFloat32: true,
            isNonInterleaved: false,
            isSupported: true
        )
        return state
    }

    /// Quiet speech-like fixture: converges auto gain well past the +3 dB
    /// low-confidence cap so cap re-clamps are observable.
    private func convergeGain(
        _ state: inout VoiceBoostAudioTapRuntimeState,
        seconds: Double,
        sampleRate: Double
    ) -> Double {
        var samples = FixtureSignal.speechLike(
            amplitude: 0.05,
            sampleRate: sampleRate,
            duration: seconds,
            channelCount: 1
        )
        var offset = 0
        let frameCount = samples.count
        while offset < frameCount {
            let block = min(blockFrames, frameCount - offset)
            samples.withUnsafeMutableBufferPointer { pointer in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(block * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(pointer.baseAddress! + offset)
                    )
                )
                state.process(bufferList: &bufferList, frameCount: block)
            }
            offset += block
        }
        return state.processor?.metrics.currentAutoGainDB ?? 0
    }

    @Test("Adaptation survives unprepare/prepare, including a sample-rate change")
    func adaptationSurvivesReprepare() {
        var state = preparedState()
        let convergedGain = convergeGain(&state, seconds: 8, sampleRate: 48_000)
        #expect(convergedGain > 4)

        state.unprepare()
        state.prepare(
            maximumFrames: blockFrames,
            sampleRate: 44_100,
            channelCount: 1,
            isFloat32: true,
            isNonInterleaved: false,
            isSupported: true
        )

        let restoredGain = state.processor?.metrics.currentAutoGainDB ?? 0
        #expect(abs(restoredGain - convergedGain) < 1e-9)

        // Quiet-intro scenario: two more seconds of quiet audio must not
        // re-clamp through the low-confidence cap.
        let continuedGain = convergeGain(&state, seconds: 2, sampleRate: 44_100)
        #expect(continuedGain > 4)
        #expect(abs(continuedGain - convergedGain) < 1.5)
    }

    @Test("Seek resets measurement but re-seeds control state")
    func seekReseedsControlState() {
        var state = preparedState()
        let convergedGain = convergeGain(&state, seconds: 8, sampleRate: 48_000)
        #expect(convergedGain > 4)

        state.reset()
        let gainAfterSeek = state.processor?.metrics.currentAutoGainDB ?? 0
        #expect(abs(gainAfterSeek - convergedGain) < 1e-9)

        // Post-seek audio in the same programme: gain must neither step nor
        // fall back to the cap.
        let continuedGain = convergeGain(&state, seconds: 2, sampleRate: 48_000)
        #expect(continuedGain > 4)
        #expect(abs(continuedGain - convergedGain) < 1.5)
    }

    @Test("Teardown mid-drain is safe and the next prepare lands in the right phase")
    func teardownMidDrainIsSafe() {
        var state = preparedState()
        var samples = FixtureSignal.sine(
            frequency: 330,
            amplitude: 0.06,
            sampleRate: sampleRate,
            frameCount: 4 * blockFrames
        )
        for block in 0..<2 {
            AudioBufferListFixture.processInterleaved(
                state: &state,
                samples: &samples,
                channelCount: 1,
                frameOffset: block * blockFrames,
                frameCount: blockFrames
            )
        }

        var disabledConfiguration = VoiceBoostConfiguration.default
        disabledConfiguration.isEnabled = false
        state.update(configuration: disabledConfiguration)
        #expect(AudioBufferListFixture.processInterleaved(
            state: &state,
            samples: &samples,
            channelCount: 1,
            frameOffset: 2 * blockFrames,
            frameCount: blockFrames
        ) == .processedTransition)
        #expect(state.phase == .disengaging)

        state.unprepare()
        state.prepare(
            maximumFrames: blockFrames,
            sampleRate: sampleRate,
            channelCount: 1,
            isFloat32: true,
            isNonInterleaved: false,
            isSupported: true
        )
        #expect(state.phase == .bypassed)

        let untouched = Array(samples[(3 * blockFrames)...])
        #expect(AudioBufferListFixture.processInterleaved(
            state: &state,
            samples: &samples,
            channelCount: 1,
            frameOffset: 3 * blockFrames,
            frameCount: blockFrames
        ) == .bypassedDisabled)
        #expect(Array(samples[(3 * blockFrames)...]) == untouched)
    }

    @Test("Enabling a tap that started disabled engages without a processor rebuild")
    func enableAfterStartingDisabledEngages() {
        var configuration = VoiceBoostConfiguration.default
        configuration.isEnabled = false
        var state = preparedState(configuration: configuration)
        var samples = FixtureSignal.sine(
            frequency: 330,
            amplitude: 0.06,
            sampleRate: sampleRate,
            frameCount: 8 * blockFrames
        )

        #expect(AudioBufferListFixture.processInterleaved(
            state: &state,
            samples: &samples,
            channelCount: 1,
            frameOffset: 0,
            frameCount: blockFrames
        ) == .bypassedDisabled)

        state.update(configuration: .default)
        var lastOutcome = VoiceBoostTapProcessOutcome.bypassedDisabled
        for block in 1..<8 {
            lastOutcome = AudioBufferListFixture.processInterleaved(
                state: &state,
                samples: &samples,
                channelCount: 1,
                frameOffset: block * blockFrames,
                frameCount: blockFrames
            )
            let start = block * blockFrames
            #expect(
                samples[start..<(start + blockFrames)]
                    .allSatisfy { $0.isFinite && abs($0) <= 4 }
            )
        }
        #expect(lastOutcome == .processedEngaged)
        #expect(state.phase == .engaged)
    }

    @Test("Bypass diagnostics split by reason and preserve the combined count")
    func bypassDiagnosticsSplitByReason() {
        let diagnostics = VoiceBoostAudioTapDiagnostics()
        diagnostics.recordProcess(frameCount: 100, outcome: .processedEngaged, durationNanoseconds: 10)
        diagnostics.recordProcess(frameCount: 200, outcome: .processedTransition, durationNanoseconds: 10)
        diagnostics.recordProcess(frameCount: 300, outcome: .bypassedDisabled, durationNanoseconds: 10)
        diagnostics.recordProcess(frameCount: 400, outcome: .bypassedContended, durationNanoseconds: 10)
        diagnostics.recordProcess(frameCount: 500, outcome: .bypassedUnsupported, durationNanoseconds: 10)

        let snapshot = diagnostics.snapshot
        #expect(snapshot.processCount == 5)
        #expect(snapshot.processedFrameCount == 300)
        #expect(snapshot.transitionFrameCount == 200)
        #expect(snapshot.disabledBypassedFrameCount == 300)
        #expect(snapshot.contentionBypassedFrameCount == 400)
        #expect(snapshot.unsupportedFormatBypassedFrameCount == 500)
        #expect(snapshot.bypassedFrameCount == 1_200)
    }
}
