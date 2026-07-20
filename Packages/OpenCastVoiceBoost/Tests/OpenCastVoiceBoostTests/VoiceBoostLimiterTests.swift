import Foundation
import Testing
@testable import OpenCastVoiceBoost

/// Pass 3 requirements for the true-peak lookahead limiter: exact ceiling
/// compliance with no hidden headroom, null transparency below threshold,
/// latency == lookahead, sliding-minimum attack that never overshoots,
/// smooth exponential release, clean reset, and a stable interplay with the
/// loudness engine's chain-loss makeup.
struct VoiceBoostLimiterTests {
    @Test(
        "Below the ceiling the limiterOnly chain is a pure delay",
        arguments: [44_100.0, 48_000.0]
    )
    func nullTransparencyBelowCeiling(sampleRate: Double) {
        let channelCount = 2
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.3,
            sampleRate: sampleRate,
            duration: 1,
            channelCount: channelCount
        )
        let original = buffer
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: channelCount
        )

        let latencyFrames = processor.metrics.latencyFrames
        #expect(latencyFrames == Int((0.005 * sampleRate).rounded(.up)))
        #expect(processor.metrics.currentLimiterReductionDB == 0)
        #expect(processor.metrics.safetyClampCount == 0)

        let latencySamples = latencyFrames * channelCount
        let delayedInput = Array(original[..<(original.count - latencySamples)])
        let delayedOutput = Array(buffer[latencySamples...])
        #expect(delayedOutput == delayedInput)
        #expect(buffer[..<latencySamples].allSatisfy { $0 == 0 })
    }

    @Test("An impulse pins latency to exactly the lookahead")
    func impulseLatencyEqualsLookahead() {
        let sampleRate = 48_000.0
        let impulseFrame = 1_000
        var buffer = [Float](repeating: 0, count: 4_800)
        buffer[impulseFrame] = 0.5
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 1,
            blockSize: 256
        )

        let latencyFrames = processor.metrics.latencyFrames
        let peakIndex = buffer.indices.max { abs(buffer[$0]) < abs(buffer[$1]) }
        #expect(peakIndex == impulseFrame + latencyFrames)
        #expect(buffer[impulseFrame + latencyFrames] == 0.5)
    }

    @Test(
        "Hot material lands at the configured ceiling exactly - no hidden headroom",
        arguments: [44_100.0, 48_000.0]
    )
    func ceilingIsHonoredExactlyWithoutHiddenHeadroom(sampleRate: Double) {
        let ceilingDBTP = -1.0
        var buffer = VoiceBoostFixtureGenerator.sine(
            frequency: 997,
            amplitude: 1.4,
            sampleRate: sampleRate,
            duration: 2,
            channelCount: 2
        )
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 2,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 2
        )

        let truePeak = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
            buffer,
            channelCount: 2,
            sampleRate: sampleRate
        )
        // The old chain parked hot tones ~1.4 dB under the ceiling (the
        // 0.85x fudge); the limiter must land at the ceiling itself.
        #expect(truePeak <= ceilingDBTP + 0.1)
        #expect(truePeak >= ceilingDBTP - 0.1)
        #expect(processor.metrics.maximumLimiterReductionDB > 2)
        #expect(processor.metrics.safetyClampCount == 0)
    }

    @Test("Sample peaks never exceed the ceiling while fully wet")
    func samplePeaksStayUnderCeiling() {
        var buffer = VoiceBoostFixtureGenerator.sine(
            frequency: 11_000,
            amplitude: 1.5,
            sampleRate: 44_100,
            duration: 1,
            channelCount: 1
        )
        let processor = VoiceBoostProcessor(
            sampleRate: 44_100,
            channelCount: 1,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 1
        )

        let ceiling = VoiceBoostFixtureGenerator.linearAmplitude(db: -1)
        #expect(VoiceBoostFixtureGenerator.maxAbs(buffer) <= ceiling)
        #expect(processor.metrics.safetyClampCount == 0)
    }

    @Test("A limited sine stays a sine - the limiter does not waveshape")
    func limitedSineStaysSine() {
        let sampleRate = 48_000.0
        let frequency = 997.0
        var buffer = VoiceBoostFixtureGenerator.sine(
            frequency: frequency,
            amplitude: 1.2,
            sampleRate: sampleRate,
            duration: 2,
            channelCount: 1
        )
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 1
        )

        #expect(processor.metrics.maximumLimiterReductionDB > 1.5)
        #expect(processor.metrics.safetyClampCount == 0)

        // Steady-state tail: project onto the fundamental; anything the
        // projection cannot explain is waveshaping (the old copysign clamp
        // squared this fixture off).
        let tailStart = Int(sampleRate * 1.0)
        let tail = buffer[tailStart...].map(Double.init)
        var sinSum = 0.0
        var cosSum = 0.0
        var energy = 0.0
        for (offset, sample) in tail.enumerated() {
            let angle = 2 * Double.pi * frequency * Double(tailStart + offset) / sampleRate
            sinSum += sample * sin(angle)
            cosSum += sample * cos(angle)
            energy += sample * sample
        }
        let count = Double(tail.count)
        let fundamentalEnergy = 2 * (sinSum * sinSum + cosSum * cosSum) / count
        let residualRatio = max(0, energy - fundamentalEnergy) / energy
        #expect(residualRatio < 0.0001)
    }

    @Test("A burst onset never overshoots the ceiling - the sliding-minimum guarantee")
    func attackNeverOvershootsOnBurstOnset() {
        let sampleRate = 48_000.0
        let quiet = VoiceBoostFixtureGenerator.sine(
            frequency: 997,
            amplitude: 0.2,
            sampleRate: sampleRate,
            duration: 0.5,
            channelCount: 1
        )
        let hot = VoiceBoostFixtureGenerator.sine(
            frequency: 997,
            amplitude: 1.4,
            sampleRate: sampleRate,
            duration: 0.5,
            channelCount: 1
        )
        var buffer = quiet + hot
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: VoiceBoostPreset.limiterOnly.configuration
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
            sampleRate: sampleRate
        )
        #expect(truePeak <= -1.0 + 0.1)
        #expect(processor.metrics.safetyClampCount == 0)
    }

    @Test("Release recovers monotonically between bursts without pumping")
    func releaseRecoversMonotonicallyBetweenBursts() {
        let sampleRate = 48_000.0
        let burstFrames = Int(sampleRate * 0.010)
        let gapFrames = Int(sampleRate * 0.110)
        let burst = VoiceBoostFixtureGenerator.sine(
            frequency: 997,
            amplitude: 1.4,
            sampleRate: sampleRate,
            duration: 0.010,
            channelCount: 1
        )
        var buffer: [Float] = []
        for _ in 0..<6 {
            buffer += burst
            buffer += [Float](repeating: 0, count: gapFrames)
        }

        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )
        let blockFrames = 128
        var reductions: [Double] = []
        var offsetFrames = 0
        let totalFrames = buffer.count
        while offsetFrames < totalFrames {
            let frameCount = min(blockFrames, totalFrames - offsetFrames)
            buffer.withUnsafeMutableBufferPointer { pointer in
                let block = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress! + offsetFrames,
                    count: frameCount
                )
                processor.processInterleavedFloat32(block, frameCount: frameCount)
            }
            reductions.append(processor.metrics.currentLimiterReductionDB)
            offsetFrames += frameCount
        }

        // Within each burst-to-burst gap the reduction must decay
        // monotonically (no pumping) and recover most of the way before the
        // next hit (100 ms release inside a 110 ms gap).
        let periodBlocks = (burstFrames + gapFrames) / blockFrames
        var recoveryChecked = 0
        for period in 1..<5 {
            let start = period * periodBlocks + 3
            let end = (period + 1) * periodBlocks - 1
            guard start < end, end <= reductions.count else {
                continue
            }
            let gapReductions = Array(reductions[start..<end])
            for (previous, next) in zip(gapReductions, gapReductions.dropFirst()) {
                #expect(next <= previous + 0.02)
            }
            let peakReduction = reductions[(period * periodBlocks)..<end].max() ?? 0
            #expect(peakReduction > 2)
            #expect(gapReductions.last! < peakReduction / 2)
            recoveryChecked += 1
        }
        #expect(recoveryChecked == 4)
    }

    @Test("Reset mid-limit clears the delay line, gain, and telemetry")
    func resetMidLimitLeavesNoStaleState() {
        let sampleRate = 48_000.0
        var hot = VoiceBoostFixtureGenerator.sine(
            frequency: 997,
            amplitude: 1.4,
            sampleRate: sampleRate,
            duration: 0.5,
            channelCount: 1
        )
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: 1,
            configuration: VoiceBoostPreset.limiterOnly.configuration
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &hot,
            processor: processor,
            channelCount: 1
        )
        #expect(processor.metrics.maximumLimiterReductionDB > 2)

        processor.reset()

        let afterReset = processor.metrics
        #expect(afterReset.currentLimiterReductionDB == 0)
        #expect(afterReset.maximumLimiterReductionDB == 0)
        #expect(afterReset.outputTruePeakDBTP == nil)
        #expect(afterReset.safetyClampCount == 0)
        #expect(afterReset.latencyFrames == 240)

        // The first lookahead window after a reset must be zero-primed
        // (no stale tone), then bit-identical delayed passthrough.
        var speech = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.2,
            sampleRate: sampleRate,
            duration: 0.25,
            channelCount: 1
        )
        let original = speech
        VoiceBoostFixtureGenerator.processInBlocks(
            &speech,
            processor: processor,
            channelCount: 1
        )
        let latencyFrames = afterReset.latencyFrames
        #expect(speech[..<latencyFrames].allSatisfy { $0 == 0 })
        #expect(Array(speech[latencyFrames...]) == Array(original[..<(original.count - latencyFrames)]))
    }

    @Test("Enabling mid-stream ramps without a click - legs blend time-aligned")
    func enableMidStreamRampsWithoutClick() {
        let sampleRate = 48_000.0
        let channelCount = 1
        let enableFrame = Int(sampleRate * 0.5)
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.16,
            sampleRate: sampleRate,
            duration: 1,
            channelCount: channelCount
        )
        let original = buffer
        var configuration = VoiceBoostConfiguration.default
        configuration.isEnabled = false
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: configuration
        )

        let totalFrames = buffer.count / channelCount
        var offsetFrames = 0
        while offsetFrames < totalFrames {
            if offsetFrames == enableFrame {
                configuration.isEnabled = true
                processor.update(configuration: configuration)
            }
            let frameCount = min(256, enableFrame > offsetFrames ? enableFrame - offsetFrames : totalFrames - offsetFrames)
            buffer.withUnsafeMutableBufferPointer { pointer in
                let block = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress! + offsetFrames * channelCount,
                    count: frameCount * channelCount
                )
                processor.processInterleavedFloat32(block, frameCount: frameCount)
            }
            offsetFrames += frameCount
        }

        #expect(buffer.allSatisfy { $0.isFinite })
        let originalMaximumStep = VoiceBoostFixtureGenerator.maximumAdjacentStep(
            original,
            channelCount: channelCount
        )
        let transitionStep = VoiceBoostFixtureGenerator.maximumAdjacentStep(
            buffer,
            channelCount: channelCount,
            frameRange: (enableFrame - 512)..<(enableFrame + 4_096)
        )
        #expect(transitionStep < max(0.04, originalMaximumStep * 8))
    }

    @Test("Chain-loss makeup and the limiter settle instead of fighting")
    func chainLossMakeupStandoffIsStable() throws {
        let sampleRate = 48_000.0
        let channelCount = 2
        var buffer = VoiceBoostFixtureGenerator.sine(
            frequency: 997,
            amplitude: 0.9,
            sampleRate: sampleRate,
            duration: 30,
            channelCount: channelCount
        )
        let processor = VoiceBoostProcessor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            configuration: .default
        )

        let blockFrames = 1_024
        let totalFrames = buffer.count / channelCount
        var offsetFrames = 0
        var tailGains: [Double] = []
        var tailReductions: [Double] = []
        var clampCount = 0
        while offsetFrames < totalFrames {
            let frameCount = min(blockFrames, totalFrames - offsetFrames)
            buffer.withUnsafeMutableBufferPointer { pointer in
                let block = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress! + offsetFrames * channelCount,
                    count: frameCount * channelCount
                )
                processor.processInterleavedFloat32(block, frameCount: frameCount)
            }
            offsetFrames += frameCount
            let metrics = processor.metrics
            clampCount = metrics.safetyClampCount
            if offsetFrames > Int(sampleRate * 20) {
                tailGains.append(metrics.currentAutoGainDB)
                tailReductions.append(metrics.currentLimiterReductionDB)
            }
        }

        let truePeak = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
            buffer,
            channelCount: channelCount,
            sampleRate: sampleRate
        )
        #expect(truePeak <= -1.0 + 0.1)
        #expect(clampCount == 0)

        // Deadband + chain-loss clamp must hold the fixed point steady: no
        // gain oscillation, and the transient convergence-ramp limiting has
        // subsided rather than settled into a makeup-versus-limiter fight.
        let minimumGain = try #require(tailGains.min())
        let maximumGain = try #require(tailGains.max())
        #expect(maximumGain - minimumGain < 1.0)
        let maximumTailReduction = try #require(tailReductions.max())
        #expect(maximumTailReduction < 0.5)
    }
}
