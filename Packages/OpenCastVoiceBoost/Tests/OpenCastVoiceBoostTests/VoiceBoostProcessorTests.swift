import Foundation
import Testing
@testable import OpenCastVoiceBoost

struct VoiceBoostProcessorTests {
    @Test("Silence remains silence")
    func silenceRemainsSilence() {
        var buffer = VoiceBoostFixtureGenerator.silence(
            sampleRate: 48_000,
            duration: 1,
            channelCount: 2
        )
        let processor = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 2)

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 2
        )

        #expect(VoiceBoostFixtureGenerator.maxAbs(buffer) < 0.000_001)
        #expect(processor.metrics.estimatedInputLUFS == nil)
    }

    @Test("NaN and Inf input is sanitized")
    func nonFiniteInputIsSanitized() {
        var buffer: [Float] = [
            .nan,
            .infinity,
            -.infinity,
            0.25,
            -0.5,
            0.5
        ]
        let processor = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 2)

        buffer.withUnsafeMutableBufferPointer { pointer in
            processor.processInterleavedFloat32(pointer, frameCount: 3)
        }

        #expect(buffer.allSatisfy { $0.isFinite })
    }

    @Test("Enabled processing does not emit clipped samples")
    func processingDoesNotClipSamples() {
        var buffer = VoiceBoostFixtureGenerator.sine(
            frequency: 997,
            amplitude: 1.4,
            sampleRate: 48_000,
            duration: 1,
            channelCount: 2
        )
        let ceiling = VoiceBoostFixtureGenerator.linearAmplitude(db: -1)
        let processor = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 2)

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 2
        )

        #expect(VoiceBoostFixtureGenerator.maxAbs(buffer) <= ceiling + 0.000_1)
        #expect(buffer.allSatisfy { $0.isFinite })
    }

    @Test("Limiter reports true peak under the configured ceiling")
    func limiterReportsTruePeakUnderCeiling() {
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
            configuration: VoiceBoostConfiguration(truePeakCeilingDBTP: -1.5)
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 1
        )

        #expect((processor.metrics.outputTruePeakDBTP ?? 0) <= -1.4)
    }

    @Test("Disabled processor is near dry-identical")
    func disabledProcessorIsDryIdentical() {
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.2,
            sampleRate: 48_000,
            duration: 0.5,
            channelCount: 2
        )
        let original = buffer
        let processor = VoiceBoostProcessor(
            sampleRate: 48_000,
            channelCount: 2,
            configuration: VoiceBoostConfiguration(isEnabled: false)
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 2
        )

        #expect(VoiceBoostFixtureGenerator.maximumDelta(buffer, original) < 0.000_001)
    }

    @Test("Enable and disable changes ramp without a discontinuity spike")
    func togglingEnabledStateRampsWithoutDiscontinuitySpike() {
        let sampleRate = 48_000.0
        let channelCount = 1
        let offFrame = Int(sampleRate * 0.40)
        let onFrame = Int(sampleRate * 0.65)
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.16,
            sampleRate: sampleRate,
            duration: 1,
            channelCount: channelCount
        )
        let original = buffer
        let processor = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channelCount)
        let totalFrames = buffer.count / channelCount
        var offsetFrames = 0
        var configuration = VoiceBoostConfiguration.default

        while offsetFrames < totalFrames {
            if offsetFrames == offFrame {
                configuration.isEnabled = false
                processor.update(configuration: configuration)
            } else if offsetFrames == onFrame {
                configuration.isEnabled = true
                processor.update(configuration: configuration)
            }

            let nextToggleFrame = [offFrame, onFrame]
                .filter { $0 > offsetFrames }
                .min() ?? totalFrames
            let frameCount = min(256, nextToggleFrame - offsetFrames, totalFrames - offsetFrames)
            let offsetSamples = offsetFrames * channelCount
            buffer.withUnsafeMutableBufferPointer { pointer in
                let block = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress! + offsetSamples,
                    count: frameCount * channelCount
                )
                processor.processInterleavedFloat32(block, frameCount: frameCount)
            }
            offsetFrames += frameCount
        }

        let originalMaximumStep = VoiceBoostFixtureGenerator.maximumAdjacentStep(
            original,
            channelCount: channelCount
        )
        let outputMaximumStep = VoiceBoostFixtureGenerator.maximumAdjacentStep(
            buffer,
            channelCount: channelCount
        )
        let offTransitionStep = VoiceBoostFixtureGenerator.maximumAdjacentStep(
            buffer,
            channelCount: channelCount,
            frameRange: (offFrame - 512)..<(offFrame + 512)
        )
        let onTransitionStep = VoiceBoostFixtureGenerator.maximumAdjacentStep(
            buffer,
            channelCount: channelCount,
            frameRange: (onFrame - 512)..<(onFrame + 512)
        )

        #expect(outputMaximumStep < 0.12)
        #expect(offTransitionStep < max(0.04, originalMaximumStep * 8))
        #expect(onTransitionStep < max(0.04, originalMaximumStep * 8))
        #expect(buffer.allSatisfy { $0.isFinite })
    }

    @Test("Already-normalized speech-like fixture changes minimally")
    func normalizedFixtureChangesMinimally() {
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.42,
            sampleRate: 48_000,
            duration: 2,
            channelCount: 2
        )
        let inputRMS = VoiceBoostFixtureGenerator.rms(buffer)
        let processor = VoiceBoostProcessor(
            sampleRate: 48_000,
            channelCount: 2,
            configuration: VoiceBoostPreset.transparent.configuration
        )

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 2
        )

        let ratio = VoiceBoostFixtureGenerator.rms(buffer) / inputRMS
        #expect(ratio > 0.70)
        #expect(ratio < 1.20)
        #expect(abs(processor.metrics.currentAutoGainDB) < 3)
    }

    @Test("Quiet speech-like fixture receives bounded gain")
    func quietFixtureReceivesBoundedGain() {
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.025,
            sampleRate: 48_000,
            duration: 4,
            channelCount: 2
        )
        let inputRMS = VoiceBoostFixtureGenerator.rms(buffer)
        let processor = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 2)

        VoiceBoostFixtureGenerator.processInBlocks(
            &buffer,
            processor: processor,
            channelCount: 2
        )

        let metrics = processor.metrics
        #expect(VoiceBoostFixtureGenerator.rms(buffer) > inputRMS * 1.5)
        #expect(metrics.currentAutoGainDB > 0)
        #expect(metrics.currentAutoGainDB <= 13.1)
    }

    @Test("Alternating quiet and loud fixture avoids abrupt auto-gain jumps")
    func alternatingFixtureAvoidsAbruptAutoGainJumps() {
        var buffer = VoiceBoostFixtureGenerator.alternatingSpeechLike(
            quietAmplitude: 0.025,
            loudAmplitude: 0.35,
            segmentDuration: 0.5,
            sampleRate: 48_000,
            duration: 6,
            channelCount: 2
        )
        let processor = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 2)
        let totalFrames = buffer.count / 2
        var offsetFrames = 0
        var gainTimeline: [Double] = []

        while offsetFrames < totalFrames {
            let frameCount = min(1_024, totalFrames - offsetFrames)
            let offsetSamples = offsetFrames * 2
            buffer.withUnsafeMutableBufferPointer { pointer in
                let block = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress! + offsetSamples,
                    count: frameCount * 2
                )
                processor.processInterleavedFloat32(block, frameCount: frameCount)
            }
            gainTimeline.append(processor.metrics.currentAutoGainDB)
            offsetFrames += frameCount
        }

        let maximumJump = zip(gainTimeline, gainTimeline.dropFirst()).reduce(0.0) { partialResult, pair in
            max(partialResult, abs(pair.1 - pair.0))
        }
        #expect(maximumJump < 1.0)
        #expect((gainTimeline.max() ?? 0) <= 13.1)
    }

    @Test("Reset clears filter and gain state")
    func resetClearsState() {
        var loudBuffer = VoiceBoostFixtureGenerator.sine(
            frequency: 220,
            amplitude: 1.0,
            sampleRate: 48_000,
            duration: 0.5,
            channelCount: 2
        )
        let processor = VoiceBoostProcessor(sampleRate: 48_000, channelCount: 2)
        VoiceBoostFixtureGenerator.processInBlocks(
            &loudBuffer,
            processor: processor,
            channelCount: 2
        )

        processor.reset()

        var silence = VoiceBoostFixtureGenerator.silence(
            sampleRate: 48_000,
            duration: 0.25,
            channelCount: 2
        )
        VoiceBoostFixtureGenerator.processInBlocks(
            &silence,
            processor: processor,
            channelCount: 2
        )

        #expect(VoiceBoostFixtureGenerator.maxAbs(silence) < 0.000_001)
        #expect(processor.metrics.estimatedInputLUFS == nil)
    }

    @Test("Mono and stereo processing work at 44.1 and 48 kHz")
    func supportedFormatsProcess() {
        for sampleRate in [44_100.0, 48_000.0] {
            for channelCount in [1, 2] {
                var buffer = VoiceBoostFixtureGenerator.speechLike(
                    amplitude: 0.08,
                    sampleRate: sampleRate,
                    duration: 1,
                    channelCount: channelCount
                )
                let processor = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channelCount)

                VoiceBoostFixtureGenerator.processInBlocks(
                    &buffer,
                    processor: processor,
                    channelCount: channelCount
                )

                #expect(buffer.allSatisfy { $0.isFinite })
                #expect(VoiceBoostFixtureGenerator.maxAbs(buffer) <= 1)
                #expect(processor.metrics.estimatedInputLUFS != nil)
            }
        }
    }
}
