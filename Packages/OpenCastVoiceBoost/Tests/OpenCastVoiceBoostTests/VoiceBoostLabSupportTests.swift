import Foundation
import Testing
@testable import VoiceBoostLabSupport

struct VoiceBoostLabSupportTests {
    @Test("Listening pack writes review artifacts without clipped samples")
    func listeningPackWritesReviewArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "opencast-voiceboost-lab-test-\(UUID().uuidString)")
        let output = root.appending(path: "listening")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appending(path: "distinctive.wav")
        let reference = root.appending(path: "delayed_reference.wav")
        let inputAudio = Self.distinctiveAudio()
        try WAVFile.write(inputAudio, to: input)
        try WAVFile.write(Self.delayedReference(audio: inputAudio, delaySeconds: 0.5), to: reference)
        try VoiceBoostLab.run(arguments: [
            "listening-pack",
            input.path,
            "--reference", reference.path,
            "--preset", "default",
            "--toggle-interval", "2",
            "--output", output.path
        ])
        let validation = output.appending(path: "validation.json")
        try VoiceBoostLab.run(arguments: [
            "validate-listening-pack",
            output.path,
            "--output", validation.path
        ])

        for fileName in [
            "dry.wav",
            "boosted.wav",
            "toggle.wav",
            "dry_metrics.json",
            "boosted_metrics.json",
            "toggle_metrics.json",
            "toggle_artifacts.json",
            "comparison.json",
            "reference.wav",
            "reference_metrics.json",
            "dry_reference_comparison.json",
            "boosted_reference_comparison.json",
            "reference_alignment.json",
            "aligned_dry.wav",
            "aligned_boosted.wav",
            "aligned_reference.wav",
            "aligned_dry_metrics.json",
            "aligned_boosted_metrics.json",
            "aligned_reference_metrics.json",
            "aligned_dry_reference_comparison.json",
            "aligned_boosted_reference_comparison.json",
            "boosted_timeline.csv",
            "summary.json",
            "validation.json",
            "listening_notes.md"
        ] {
            #expect(FileManager.default.fileExists(atPath: output.appending(path: fileName).path))
        }

        let boosted = try JSONDecoder().decode(
            AudioMetrics.self,
            from: Data(contentsOf: output.appending(path: "boosted_metrics.json"))
        )
        let toggle = try JSONDecoder().decode(
            AudioMetrics.self,
            from: Data(contentsOf: output.appending(path: "toggle_metrics.json"))
        )
        let referenceMetrics = try JSONDecoder().decode(
            AudioMetrics.self,
            from: Data(contentsOf: output.appending(path: "reference_metrics.json"))
        )
        let boostedReferenceComparison = try JSONDecoder().decode(
            ComparisonMetrics.self,
            from: Data(contentsOf: output.appending(path: "boosted_reference_comparison.json"))
        )
        let referenceAlignment = try JSONDecoder().decode(
            ReferenceAlignmentMetrics.self,
            from: Data(contentsOf: output.appending(path: "reference_alignment.json"))
        )
        let toggleArtifacts = try JSONDecoder().decode(
            ToggleArtifactMetrics.self,
            from: Data(contentsOf: output.appending(path: "toggle_artifacts.json"))
        )
        let summary = try JSONDecoder().decode(
            ListeningPackSummary.self,
            from: Data(contentsOf: output.appending(path: "summary.json"))
        )
        let validationResult = try JSONDecoder().decode(
            ListeningPackValidationResult.self,
            from: Data(contentsOf: validation)
        )
        let notes = try String(contentsOf: output.appending(path: "listening_notes.md"), encoding: .utf8)

        #expect(boosted.clippedSampleCount == 0)
        #expect(boosted.nanInfSampleCount == 0)
        #expect(toggle.clippedSampleCount == 0)
        #expect(toggle.nanInfSampleCount == 0)
        #expect(referenceMetrics.nanInfSampleCount == 0)
        #expect(boostedReferenceComparison.loudnessDeltaLU != nil)
        #expect(abs(referenceAlignment.estimatedReferenceDelaySeconds - 0.5) < 0.03)
        #expect(referenceAlignment.correlation > 0.9)
        #expect(toggleArtifacts.transitionCount == 2)
        #expect(toggleArtifacts.maxBoundaryAdjacentStep <= toggleArtifacts.maxFileAdjacentStep)
        #expect(summary.files.contains("toggle_artifacts.json"))
        #expect(summary.files.contains("aligned_boosted.wav"))
        #expect(summary.toggleArtifacts.transitionCount == 2)
        #expect(summary.alignedBoostedToReference?.loudnessDeltaLU != nil)
        #expect(summary.reviewWarnings.contains { $0.contains("human listening") })
        #expect(summary.readiness.metricOnly)
        #expect(summary.readiness.humanListeningRequired)
        #expect(summary.readiness.deviceRuntimeRequired)
        #expect(!summary.readiness.releaseApproved)
        #expect(validationResult.passed)
        #expect(validationResult.missingFiles.isEmpty)
        #expect(validationResult.errors.isEmpty)
        #expect(validationResult.warnings.contains { $0.contains("human listening") })
        #expect(notes.contains("Human listening notes are still required"))
        #expect(notes.contains("Toggle artifact"))
        #expect(notes.contains("Reference comparison"))
    }

    @Test("Listening pack validator writes failure report and throws")
    func listeningPackValidatorWritesFailureReport() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "opencast-voiceboost-validation-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let validation = root.appending(path: "validation.json")
        var didThrow = false

        do {
            try VoiceBoostLab.run(arguments: [
                "validate-listening-pack",
                root.path,
                "--output", validation.path
            ])
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(FileManager.default.fileExists(atPath: validation.path))

        let result = try JSONDecoder().decode(
            ListeningPackValidationResult.self,
            from: Data(contentsOf: validation)
        )
        #expect(!result.passed)
        #expect(result.missingFiles.contains("summary.json"))
        #expect(result.errors.contains("Missing summary.json."))
    }

    private static func delayedReference(audio: WAVAudio, delaySeconds: Double) -> WAVAudio {
        let delayFrames = Int((delaySeconds * audio.sampleRate).rounded())
        let delaySamples = delayFrames * audio.channelCount
        let keptSamples = max(0, audio.samples.count - delaySamples)
        let samples = Array(repeating: Float(0), count: delaySamples) + Array(audio.samples.prefix(keptSamples))

        return WAVAudio(
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            samples: samples
        )
    }

    private static func distinctiveAudio() -> WAVAudio {
        let sampleRate = 48_000.0
        let channelCount = 2
        let segments: [(duration: Double, amplitude: Double)] = [
            (0.42, 0.03),
            (0.58, 0.22),
            (0.31, 0.06),
            (0.83, 0.28),
            (0.47, 0.04),
            (0.69, 0.17),
            (0.36, 0.08),
            (0.91, 0.24)
        ]
        let frameCount = Int((segments.reduce(0.0) { $0 + $1.duration } * sampleRate).rounded())
        var samples = [Float](repeating: 0, count: frameCount * channelCount)
        var frameOffset = 0

        for segment in segments {
            let segmentFrames = Int((segment.duration * sampleRate).rounded())
            for frame in frameOffset..<min(frameOffset + segmentFrames, frameCount) {
                let time = Double(frame) / sampleRate
                let carrier = 0.62 * sin(2 * Double.pi * 173 * time)
                    + 0.27 * sin(2 * Double.pi * 727 * time)
                    + 0.11 * sin(2 * Double.pi * 2341 * time)
                let syllable = 0.75 + 0.25 * sin(2 * Double.pi * 6.3 * time)
                let sample = Float(segment.amplitude * syllable * carrier)
                samples[frame * channelCount] = sample
                samples[frame * channelCount + 1] = sample * 0.97
            }
            frameOffset += segmentFrames
        }

        return WAVAudio(
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: samples
        )
    }
}
