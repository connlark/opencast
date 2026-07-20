import Foundation
import Testing
@testable import OpenCastVoiceBoost

/// EBU Tech 3341 "minimum requirements" compliance cases (Table 1),
/// synthesized per the spec: stereo 1 kHz sines, in phase in both channels,
/// at per-channel peak levels and durations defined per case. Cases 6 (5.0
/// channel) and 7-8 (authentic programme files) are out of scope for a
/// mono/stereo engine without the EBU reference media.
///
/// Both meters are exercised: the offline analyzer as the strict file-based
/// meter, and the realtime engine's rolling gated model, whose 60 s window
/// covers every case's gated material at full length.
struct VoiceBoostTech3341Tests {
    private struct ToneSegment {
        var seconds: Double
        var peakDBFS: Double
    }

    private struct MinimumRequirementCase {
        var name: String
        var segments: [ToneSegment]
        var expectedLUFS: Double
        var checksMomentaryAndShortTerm: Bool
    }

    private static let cases: [MinimumRequirementCase] = [
        MinimumRequirementCase(
            name: "case 1: 20 s at -23 dBFS",
            segments: [ToneSegment(seconds: 20, peakDBFS: -23)],
            expectedLUFS: -23.0,
            checksMomentaryAndShortTerm: true
        ),
        MinimumRequirementCase(
            name: "case 2: 20 s at -33 dBFS",
            segments: [ToneSegment(seconds: 20, peakDBFS: -33)],
            expectedLUFS: -33.0,
            checksMomentaryAndShortTerm: true
        ),
        MinimumRequirementCase(
            name: "case 3: -36 / -23 / -36 dBFS",
            segments: [
                ToneSegment(seconds: 10, peakDBFS: -36),
                ToneSegment(seconds: 60, peakDBFS: -23),
                ToneSegment(seconds: 10, peakDBFS: -36)
            ],
            expectedLUFS: -23.0,
            checksMomentaryAndShortTerm: false
        ),
        MinimumRequirementCase(
            name: "case 4: -72 / -36 / -23 / -36 / -72 dBFS",
            segments: [
                ToneSegment(seconds: 10, peakDBFS: -72),
                ToneSegment(seconds: 10, peakDBFS: -36),
                ToneSegment(seconds: 60, peakDBFS: -23),
                ToneSegment(seconds: 10, peakDBFS: -36),
                ToneSegment(seconds: 10, peakDBFS: -72)
            ],
            expectedLUFS: -23.0,
            checksMomentaryAndShortTerm: false
        ),
        MinimumRequirementCase(
            name: "case 5: -26 / 20.1 s -20 / -26 dBFS",
            segments: [
                ToneSegment(seconds: 20, peakDBFS: -26),
                ToneSegment(seconds: 20.1, peakDBFS: -20),
                ToneSegment(seconds: 20, peakDBFS: -26)
            ],
            expectedLUFS: -23.0,
            checksMomentaryAndShortTerm: false
        )
    ]

    @Test(
        "Offline analyzer passes the minimum-requirement cases",
        arguments: [48_000.0, 44_100.0]
    )
    func offlineAnalyzerMeetsMinimumRequirements(sampleRate: Double) throws {
        for testCase in Self.cases {
            let buffer = Self.toneSequence(testCase.segments, sampleRate: sampleRate)
            let analysis = VoiceBoostLoudnessAnalyzer.analyzeInterleavedFloat32(
                buffer,
                sampleRate: sampleRate,
                channelCount: 2
            )

            let integrated = try #require(analysis.integratedLUFS, Comment(rawValue: testCase.name))
            #expect(abs(integrated - testCase.expectedLUFS) <= 0.1, Comment(rawValue: testCase.name))

            if testCase.checksMomentaryAndShortTerm {
                let momentary = try #require(analysis.momentaryLUFS.last)
                let shortTerm = try #require(analysis.shortTermLUFS.last)
                #expect(abs(momentary - testCase.expectedLUFS) <= 0.1, Comment(rawValue: testCase.name))
                #expect(abs(shortTerm - testCase.expectedLUFS) <= 0.1, Comment(rawValue: testCase.name))
            }
        }
    }

    @Test(
        "Realtime engine passes the minimum-requirement cases",
        arguments: [48_000.0, 44_100.0]
    )
    func realtimeEngineMeetsMinimumRequirements(sampleRate: Double) throws {
        for testCase in Self.cases {
            var buffer = Self.toneSequence(testCase.segments, sampleRate: sampleRate)
            let processor = VoiceBoostProcessor(
                sampleRate: sampleRate,
                channelCount: 2,
                configuration: VoiceBoostConfiguration(isEnabled: false)
            )
            VoiceBoostFixtureGenerator.processInBlocks(
                &buffer,
                processor: processor,
                channelCount: 2
            )

            let metrics = processor.metrics
            let integrated = try #require(metrics.integratedInputLUFS, Comment(rawValue: testCase.name))
            #expect(abs(integrated - testCase.expectedLUFS) <= 0.1, Comment(rawValue: testCase.name))

            if testCase.checksMomentaryAndShortTerm {
                let momentary = try #require(metrics.momentaryInputLUFS)
                let shortTerm = try #require(metrics.shortTermInputLUFS)
                #expect(abs(momentary - testCase.expectedLUFS) <= 0.1, Comment(rawValue: testCase.name))
                #expect(abs(shortTerm - testCase.expectedLUFS) <= 0.1, Comment(rawValue: testCase.name))
            }
        }
    }

    /// In-phase stereo 1 kHz sine at the given per-channel peak levels,
    /// phase-continuous across segment boundaries.
    private static func toneSequence(
        _ segments: [ToneSegment],
        sampleRate: Double
    ) -> [Float] {
        let channelCount = 2
        let totalFrames = segments.reduce(0) { partial, segment in
            partial + Int((segment.seconds * sampleRate).rounded())
        }
        var buffer = [Float](repeating: 0, count: totalFrames * channelCount)
        var frame = 0

        for segment in segments {
            let amplitude = pow(10, segment.peakDBFS / 20)
            let segmentFrames = Int((segment.seconds * sampleRate).rounded())
            for _ in 0..<segmentFrames {
                let time = Double(frame) / sampleRate
                let sample = Float(amplitude * sin(2 * Double.pi * 1_000 * time))
                buffer[frame * channelCount] = sample
                buffer[frame * channelCount + 1] = sample
                frame += 1
            }
        }

        return buffer
    }
}
