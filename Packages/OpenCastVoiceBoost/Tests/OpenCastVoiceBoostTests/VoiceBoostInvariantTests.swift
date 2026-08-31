import Foundation
import Testing
@testable import OpenCastVoiceBoost

/// Safety invariants that must survive every VoiceBoost overhaul pass:
/// finite output always, exact dry bypass when disabled, and true-peak
/// ceiling compliance measured with the offline 4x analyzer.
struct VoiceBoostInvariantTests {
    @Test(
        "Hostile input blocks produce finite bounded output",
        arguments: [44_100.0, 48_000.0], [1, 2]
    )
    func hostileInputProducesFiniteOutput(sampleRate: Double, channelCount: Int) {
        let processor = VoiceBoostProcessor(sampleRate: sampleRate, channelCount: channelCount)
        let hostileValues: [Float] = [
            .nan, .infinity, -.infinity, 4, -4, 3.9, -3.9,
            .leastNonzeroMagnitude, -.leastNonzeroMagnitude, 0
        ]
        var rng = SplitMix64(seed: 0x5EED_CAFE)

        for _ in 0..<200 {
            let frameCount = Int(rng.next() % 512) + 1
            var block = (0..<(frameCount * channelCount)).map { _ -> Float in
                if rng.next() % 4 == 0 {
                    hostileValues[Int(rng.next() % UInt64(hostileValues.count))]
                } else {
                    Float(bitPattern: UInt32(truncatingIfNeeded: rng.next()))
                }
            }

            block.withUnsafeMutableBufferPointer { pointer in
                processor.processInterleavedFloat32(pointer, frameCount: frameCount)
            }

            #expect(block.allSatisfy { $0.isFinite && abs($0) <= 4.0 })
        }
    }

    @Test("Enabled output true peak stays under the ceiling at 4x oversampling")
    func enabledOutputTruePeakStaysUnderCeiling() {
        let cases: [(buffer: [Float], sampleRate: Double, channelCount: Int, ceilingDBTP: Double)] = [
            (
                VoiceBoostFixtureGenerator.sine(
                    frequency: 997, amplitude: 1.4, sampleRate: 48_000, duration: 2, channelCount: 2
                ),
                48_000, 2, -1
            ),
            (
                VoiceBoostFixtureGenerator.sine(
                    frequency: 11_000, amplitude: 1.5, sampleRate: 44_100, duration: 2, channelCount: 1
                ),
                44_100, 1, -1.5
            ),
            (
                VoiceBoostFixtureGenerator.alternatingSpeechLike(
                    quietAmplitude: 0.05,
                    loudAmplitude: 0.9,
                    segmentDuration: 0.5,
                    sampleRate: 48_000,
                    duration: 4,
                    channelCount: 2
                ),
                48_000, 2, -1
            )
        ]

        for testCase in cases {
            var buffer = testCase.buffer
            var configuration = VoiceBoostConfiguration.default
            configuration.truePeakCeilingDBTP = testCase.ceilingDBTP
            let processor = VoiceBoostProcessor(
                sampleRate: testCase.sampleRate,
                channelCount: testCase.channelCount,
                configuration: configuration
            )

            VoiceBoostFixtureGenerator.processInBlocks(
                &buffer,
                processor: processor,
                channelCount: testCase.channelCount
            )

            let truePeak = VoiceBoostTruePeakAnalyzer.truePeakDBTP(
                buffer,
                channelCount: testCase.channelCount
            )
            #expect(truePeak <= testCase.ceilingDBTP + 0.1)
            #expect(buffer.allSatisfy { $0.isFinite })
        }
    }

    /// The C pipeline always runs through the limiter delay
    /// line, so C-level disabled output is the dry signal delayed by exactly
    /// `latencyFrames`, bit-identically. The zero-latency bit-identical
    /// bypass invariant lives at the tap level, whose `!isEnabled`
    /// short-circuit never invokes the processor (pinned in
    /// OpenCastPlayback's tap tests).
    @Test("Disabled processor passes finite in-range audio through as bit-identical delayed dry")
    func disabledProcessorIsBitIdenticalDelayedDry() {
        var buffer = VoiceBoostFixtureGenerator.speechLike(
            amplitude: 0.9,
            sampleRate: 48_000,
            duration: 1,
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

        let latencySamples = processor.metrics.latencyFrames * 2
        #expect(buffer[..<latencySamples].allSatisfy { $0 == 0 })
        #expect(Array(buffer[latencySamples...]) == Array(original[..<(original.count - latencySamples)]))
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
