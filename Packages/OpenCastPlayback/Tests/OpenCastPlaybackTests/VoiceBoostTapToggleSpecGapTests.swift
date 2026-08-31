import Foundation
import OpenCastVoiceBoost
import Testing
@testable import OpenCastPlayback

/// Disabling Voice Boost drains through the C crossfade (time-aligned wet/dry legs),
/// splices the delayed dry output back onto the live signal over ~5 ms, and
/// only then parks in the bit-identical zero-latency bypass. Enabling takes
/// the mirrored path. No cuts, no forward skips, no wedged states.
struct VoiceBoostTapToggleSpecGapTests {
    private let sampleRate = 48_000.0
    private let blockFrames = 1_024
    private let warmupBlocks = 281
    // 5 ms is not a whole 330 Hz period, so the latency splice genuinely
    // blends out-of-phase copies; a frequency whose period divides the
    // lookahead would hide splice artifacts.
    private let toneFrequency = 330.0
    private let toneAmplitude = 0.06

    private func preparedState() -> VoiceBoostAudioTapRuntimeState {
        var state = VoiceBoostAudioTapRuntimeState(configuration: .default)
        state.prepare(
            maximumFrames: blockFrames,
            sampleRate: sampleRate,
            channelCount: 1,
            isFloat32: true,
            isNonInterleaved: false,
            isSupported: true
        )
        return state
    }

    private func makeTone(blocks: Int) -> [Float] {
        FixtureSignal.sine(
            frequency: toneFrequency,
            amplitude: toneAmplitude,
            sampleRate: sampleRate,
            frameCount: blocks * blockFrames
        )
    }

    @discardableResult
    private func processBlock(
        _ state: inout VoiceBoostAudioTapRuntimeState,
        _ samples: inout [Float],
        block: Int
    ) -> VoiceBoostTapProcessOutcome {
        AudioBufferListFixture.processInterleaved(
            state: &state,
            samples: &samples,
            channelCount: 1,
            frameOffset: block * blockFrames,
            frameCount: blockFrames
        )
    }

    private func rms(_ buffer: ArraySlice<Float>) -> Double {
        guard !buffer.isEmpty else {
            return 0
        }
        let sumSquares = buffer.reduce(0.0) { partialResult, sample in
            partialResult + Double(sample) * Double(sample)
        }
        return (sumSquares / Double(buffer.count)).squareRoot()
    }

    private func maxAdjacentStep(_ buffer: ArraySlice<Float>) -> Double {
        var maximum = 0.0
        var previous: Float?
        for sample in buffer {
            if let previous {
                maximum = max(maximum, abs(Double(sample - previous)))
            }
            previous = sample
        }
        return maximum
    }

    @Test("Disabling drains through the ramp and lands in bit-identical dry")
    func disableRampsAndTerminatesBitIdenticalDry() {
        var state = preparedState()
        let totalBlocks = warmupBlocks + 8
        var samples = makeTone(blocks: totalBlocks)
        let original = samples

        for block in 0..<warmupBlocks {
            #expect(processBlock(&state, &samples, block: block).wasProcessed)
        }

        var disabledConfiguration = VoiceBoostConfiguration.default
        disabledConfiguration.isEnabled = false
        state.update(configuration: disabledConfiguration)

        var outcomes: [VoiceBoostTapProcessOutcome] = []
        for block in warmupBlocks..<totalBlocks {
            outcomes.append(processBlock(&state, &samples, block: block))
        }

        // The first post-toggle buffer must still be processed (the drain),
        // and the tail must reach the steady-state bypass.
        #expect(outcomes.first == .processedTransition)
        #expect(outcomes.suffix(3).allSatisfy { $0 == .bypassedDisabled })

        let boundary = warmupBlocks * blockFrames
        let window = Int(sampleRate * 0.005)

        // A 50 ms ramp keeps the first 5 ms after the toggle near the wet
        // level; the old short-circuit dropped -10.8 dB in one buffer.
        let preLevel = rms(samples[(boundary - window)..<boundary])
        let postLevel = rms(samples[boundary..<(boundary + window)])
        #expect(abs(20 * log10(postLevel / preLevel)) < 3)

        // The whole trajectory ramps: no 5 ms window steps more than 3 dB
        // from its neighbor anywhere across the transition.
        var previousLevel = preLevel
        for windowIndex in 0..<30 {
            let start = boundary + windowIndex * window
            let level = rms(samples[start..<(start + window)])
            #expect(abs(20 * log10(level / previousLevel)) < 3)
            previousLevel = level
        }

        // No sample-level click: transition steps stay within the intrinsic
        // step range of the wet signal itself.
        let wetStepBound = 1.5 * maxAdjacentStep(
            samples[(boundary - 4 * window)..<boundary]
        )
        let transitionStep = maxAdjacentStep(samples[boundary..<(boundary + 20 * window)])
        #expect(transitionStep <= wetStepBound)

        // Terminal state: buffers pass through untouched.
        let terminalStart = (warmupBlocks + 5) * blockFrames
        #expect(Array(samples[terminalStart...]) == Array(original[terminalStart...]))
    }

    @Test("Re-enabling after full bypass restores gain and fades back in cleanly")
    func reenableAfterBypassRestoresGainWithoutClick() {
        var state = preparedState()
        let resumeBlocks = 70
        let totalBlocks = warmupBlocks + 8 + resumeBlocks
        var samples = makeTone(blocks: totalBlocks)

        for block in 0..<warmupBlocks {
            processBlock(&state, &samples, block: block)
        }
        let convergedGain = state.processor?.metrics.currentAutoGainDB ?? 0
        let wetRange = ((warmupBlocks - 1) * blockFrames)..<(warmupBlocks * blockFrames)
        let wetLevel = rms(samples[wetRange])
        let wetIntrinsicStep = maxAdjacentStep(samples[wetRange])
        #expect(convergedGain > 3)

        var disabledConfiguration = VoiceBoostConfiguration.default
        disabledConfiguration.isEnabled = false
        state.update(configuration: disabledConfiguration)
        for block in warmupBlocks..<(warmupBlocks + 8) {
            processBlock(&state, &samples, block: block)
        }
        #expect(state.phase == .bypassed)

        state.update(configuration: .default)
        // Reset-on-reengage plus control re-seed: the delay line starts
        // fresh but adaptation resumes at the pre-disable gain.
        let restoredGain = state.processor?.metrics.currentAutoGainDB ?? 0
        #expect(abs(restoredGain - convergedGain) < 1e-9)

        let resumeStart = warmupBlocks + 8
        var outcomes: [VoiceBoostTapProcessOutcome] = []
        for block in resumeStart..<totalBlocks {
            outcomes.append(processBlock(&state, &samples, block: block))
        }
        #expect(outcomes.allSatisfy { $0.wasProcessed })
        #expect(state.phase == .engaged)

        // No click across the enable boundary: the warmup window holds pure
        // live output, then the splice fades the processed leg in from zero
        // and the in-processor ramp brings the boost up. Steps stay within
        // the intrinsic step range of the fully wet signal; a cut from dry
        // straight to wet would exceed it by an order of magnitude.
        let enableBoundary = resumeStart * blockFrames
        let window = Int(sampleRate * 0.005)
        let enableStep = maxAdjacentStep(
            samples[enableBoundary..<(enableBoundary + 20 * window)]
        )
        #expect(enableStep <= 1.5 * wetIntrinsicStep)

        // Level returns to the wet level once the in-processor ramp lands.
        let finalLevel = rms(samples[((totalBlocks - 1) * blockFrames)...])
        #expect(abs(20 * log10(finalLevel / wetLevel)) < 1.5)
    }

    @Test("Re-enabling mid-drain cancels cleanly and returns to the wet level")
    func reenableMidDrainCancelsCleanly() {
        var state = preparedState()
        let resumeBlocks = 70
        let totalBlocks = warmupBlocks + 1 + resumeBlocks
        var samples = makeTone(blocks: totalBlocks)

        for block in 0..<warmupBlocks {
            processBlock(&state, &samples, block: block)
        }
        let wetLevel = rms(
            samples[((warmupBlocks - 1) * blockFrames)..<(warmupBlocks * blockFrames)]
        )

        var disabledConfiguration = VoiceBoostConfiguration.default
        disabledConfiguration.isEnabled = false
        state.update(configuration: disabledConfiguration)
        #expect(processBlock(&state, &samples, block: warmupBlocks) == .processedTransition)
        #expect(state.phase == .disengaging)

        state.update(configuration: .default)
        #expect(state.phase == .engaged)

        for block in (warmupBlocks + 1)..<totalBlocks {
            #expect(processBlock(&state, &samples, block: block).wasProcessed)
        }

        let finalLevel = rms(samples[((totalBlocks - 1) * blockFrames)...])
        #expect(abs(20 * log10(finalLevel / wetLevel)) < 1.5)
    }

    @Test("Rapid random toggles never wedge and always land in the right terminal state")
    func rapidToggleFuzzReachesCorrectTerminalState() {
        var state = preparedState()
        let fuzzBlocks = 300
        let totalBlocks = fuzzBlocks + 20
        var samples = makeTone(blocks: totalBlocks)
        let original = samples

        var rngState: UInt64 = 0x5EED_50DA
        func nextRandom() -> UInt64 {
            rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return rngState >> 33
        }

        var enabled = true
        for block in 0..<fuzzBlocks {
            if nextRandom() % 4 == 0 {
                enabled.toggle()
                var configuration = VoiceBoostConfiguration.default
                configuration.isEnabled = enabled
                state.update(configuration: configuration)
            }
            processBlock(&state, &samples, block: block)
            let start = block * blockFrames
            #expect(
                samples[start..<(start + blockFrames)]
                    .allSatisfy { $0.isFinite && abs($0) <= 4 }
            )
        }

        // Terminal disable: drains to untouched bypass.
        var disabledConfiguration = VoiceBoostConfiguration.default
        disabledConfiguration.isEnabled = false
        state.update(configuration: disabledConfiguration)
        for block in fuzzBlocks..<(fuzzBlocks + 10) {
            processBlock(&state, &samples, block: block)
        }
        let terminalDisabledBlock = fuzzBlocks + 9
        #expect(processBlock(&state, &samples, block: terminalDisabledBlock) == .bypassedDisabled)
        let terminalStart = terminalDisabledBlock * blockFrames
        #expect(
            Array(samples[terminalStart..<(terminalStart + blockFrames)])
                == Array(original[terminalStart..<(terminalStart + blockFrames)])
        )

        // Terminal enable: engages and processes.
        state.update(configuration: .default)
        var lastOutcome = VoiceBoostTapProcessOutcome.bypassedDisabled
        for block in (fuzzBlocks + 10)..<totalBlocks {
            lastOutcome = processBlock(&state, &samples, block: block)
        }
        #expect(lastOutcome == .processedEngaged)
        #expect(state.phase == .engaged)
    }
}
