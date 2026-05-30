import Foundation
import OpenCastVoiceBoost

struct ListeningPackResult {
    var dryAudio: WAVAudio
    var boostedResult: ProcessResult
    var toggleAudio: WAVAudio
    var toggleMetrics: AudioMetrics
    var toggleArtifactMetrics: ToggleArtifactMetrics
    var toggleIntervalSeconds: Double
    var referenceAudio: WAVAudio?
    var referenceMetrics: AudioMetrics?
    var dryReferenceComparison: ComparisonMetrics?
    var boostedReferenceComparison: ComparisonMetrics?
    var referenceAlignment: ReferenceAlignmentBundle?
}

enum ListeningPack {
    static func make(
        audio: WAVAudio,
        referenceAudio: WAVAudio? = nil,
        configuration: VoiceBoostConfiguration,
        toggleIntervalSeconds: Double
    ) throws -> ListeningPackResult {
        guard toggleIntervalSeconds.isFinite, toggleIntervalSeconds > 0 else {
            throw LabError.invalidArguments("--toggle-interval must be greater than zero.")
        }

        let boostedResult = LabProcessor.process(audio, configuration: configuration)
        let toggleAudio = makeToggleAudio(
            audio: audio,
            configuration: configuration,
            toggleIntervalSeconds: toggleIntervalSeconds
        )
        let referenceMetrics = referenceAudio.map { AudioMetrics.make(audio: $0) }
        let referenceAlignment = referenceAudio.flatMap {
            ReferenceAlignment.make(
                dryAudio: audio,
                boostedAudio: boostedResult.processedAudio,
                referenceAudio: $0
            )
        }

        return ListeningPackResult(
            dryAudio: audio,
            boostedResult: boostedResult,
            toggleAudio: toggleAudio,
            toggleMetrics: AudioMetrics.make(audio: toggleAudio),
            toggleArtifactMetrics: ToggleArtifactMetrics.make(
                audio: toggleAudio,
                toggleIntervalSeconds: toggleIntervalSeconds
            ),
            toggleIntervalSeconds: toggleIntervalSeconds,
            referenceAudio: referenceAudio,
            referenceMetrics: referenceMetrics,
            dryReferenceComparison: referenceMetrics.map {
                ComparisonMetrics(input: $0, output: boostedResult.inputMetrics)
            },
            boostedReferenceComparison: referenceMetrics.map {
                ComparisonMetrics(input: $0, output: boostedResult.outputMetrics)
            },
            referenceAlignment: referenceAlignment
        )
    }

    static func write(
        _ result: ListeningPackResult,
        inputURL: URL,
        to outputDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        try WAVFile.write(result.dryAudio, to: outputDirectory.appending(path: "dry.wav"))
        try WAVFile.write(result.boostedResult.processedAudio, to: outputDirectory.appending(path: "boosted.wav"))
        try WAVFile.write(result.toggleAudio, to: outputDirectory.appending(path: "toggle.wav"))

        try JSONFile.write(result.boostedResult.inputMetrics, to: outputDirectory.appending(path: "dry_metrics.json"))
        try JSONFile.write(result.boostedResult.outputMetrics, to: outputDirectory.appending(path: "boosted_metrics.json"))
        try JSONFile.write(result.toggleMetrics, to: outputDirectory.appending(path: "toggle_metrics.json"))
        try JSONFile.write(result.toggleArtifactMetrics, to: outputDirectory.appending(path: "toggle_artifacts.json"))
        try JSONFile.write(result.boostedResult.comparisonMetrics, to: outputDirectory.appending(path: "comparison.json"))
        if let referenceAudio = result.referenceAudio,
           let referenceMetrics = result.referenceMetrics,
           let dryReferenceComparison = result.dryReferenceComparison,
           let boostedReferenceComparison = result.boostedReferenceComparison {
            try WAVFile.write(referenceAudio, to: outputDirectory.appending(path: "reference.wav"))
            try JSONFile.write(referenceMetrics, to: outputDirectory.appending(path: "reference_metrics.json"))
            try JSONFile.write(
                dryReferenceComparison,
                to: outputDirectory.appending(path: "dry_reference_comparison.json")
            )
            try JSONFile.write(
                boostedReferenceComparison,
                to: outputDirectory.appending(path: "boosted_reference_comparison.json")
            )
        }
        if let referenceAlignment = result.referenceAlignment {
            try JSONFile.write(
                referenceAlignment.metrics,
                to: outputDirectory.appending(path: "reference_alignment.json")
            )
            try WAVFile.write(
                referenceAlignment.alignedDryAudio,
                to: outputDirectory.appending(path: "aligned_dry.wav")
            )
            try WAVFile.write(
                referenceAlignment.alignedBoostedAudio,
                to: outputDirectory.appending(path: "aligned_boosted.wav")
            )
            try WAVFile.write(
                referenceAlignment.alignedReferenceAudio,
                to: outputDirectory.appending(path: "aligned_reference.wav")
            )
            try JSONFile.write(
                referenceAlignment.alignedDryMetrics,
                to: outputDirectory.appending(path: "aligned_dry_metrics.json")
            )
            try JSONFile.write(
                referenceAlignment.alignedBoostedMetrics,
                to: outputDirectory.appending(path: "aligned_boosted_metrics.json")
            )
            try JSONFile.write(
                referenceAlignment.alignedReferenceMetrics,
                to: outputDirectory.appending(path: "aligned_reference_metrics.json")
            )
            try JSONFile.write(
                referenceAlignment.alignedDryReferenceComparison,
                to: outputDirectory.appending(path: "aligned_dry_reference_comparison.json")
            )
            try JSONFile.write(
                referenceAlignment.alignedBoostedReferenceComparison,
                to: outputDirectory.appending(path: "aligned_boosted_reference_comparison.json")
            )
        }
        try result.boostedResult.timeline.csvString().write(
            to: outputDirectory.appending(path: "boosted_timeline.csv"),
            atomically: true,
            encoding: .utf8
        )
        try JSONFile.write(
            ListeningPackSummary(result: result, inputURL: inputURL),
            to: outputDirectory.appending(path: "summary.json")
        )
        try listeningNotesTemplate(
            inputURL: inputURL,
            toggleIntervalSeconds: result.toggleIntervalSeconds
        ).write(
            to: outputDirectory.appending(path: "listening_notes.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func makeToggleAudio(
        audio: WAVAudio,
        configuration: VoiceBoostConfiguration,
        toggleIntervalSeconds: Double
    ) -> WAVAudio {
        var samples = audio.samples
        var disabledConfiguration = configuration
        disabledConfiguration.isEnabled = false
        var enabledConfiguration = configuration
        enabledConfiguration.isEnabled = true

        let processor = VoiceBoostProcessor(
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            configuration: disabledConfiguration
        )
        let blockFrames = max(1, Int((0.050 * audio.sampleRate).rounded()))
        let totalFrames = audio.frameCount
        var offsetFrames = 0
        var isCurrentlyEnabled = false

        while offsetFrames < totalFrames {
            let timeSeconds = Double(offsetFrames) / audio.sampleRate
            let shouldEnable = Int(timeSeconds / toggleIntervalSeconds).isMultiple(of: 2) == false
            if shouldEnable != isCurrentlyEnabled {
                processor.update(configuration: shouldEnable ? enabledConfiguration : disabledConfiguration)
                isCurrentlyEnabled = shouldEnable
            }

            let frameCount = min(blockFrames, totalFrames - offsetFrames)
            let offsetSamples = offsetFrames * audio.channelCount
            let sampleCount = frameCount * audio.channelCount
            samples.withUnsafeMutableBufferPointer { pointer in
                let block = UnsafeMutableBufferPointer(
                    start: pointer.baseAddress! + offsetSamples,
                    count: sampleCount
                )
                processor.processInterleavedFloat32(block, frameCount: frameCount)
            }

            offsetFrames += frameCount
        }

        return WAVAudio(
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            samples: samples
        )
    }

    private static func listeningNotesTemplate(
        inputURL: URL,
        toggleIntervalSeconds: Double
    ) -> String {
        """
        # Voice Boost Listening Notes

        Input: \(inputURL.path)
        Toggle interval: \(toggleIntervalSeconds) seconds

        Files:

        - `dry.wav`: unprocessed input
        - `boosted.wav`: Voice Boost output
        - `toggle.wav`: starts dry, then alternates Voice Boost on/off at the interval above
        - `toggle_artifacts.json`: adjacent-step metrics around toggle boundaries
        - `summary.json`: quick metrics summary for review
        - `reference.wav`: optional black-box reference capture when `--reference` is supplied
        - `aligned_*.wav`: optional time-aligned crops when the reference format matches

        Metrics are an automated lab aid only. Human listening notes are still required before release.
        Reference alignment is approximate and must not be treated as proof of perceptual equivalence.

        Listen at one fixed system volume before changing settings.

        | Check | Result | Notes |
        | --- | --- | --- |
        | Quiet speaker lift | Untested | |
        | Loud speaker control | Untested | |
        | Noise clarity | Untested | |
        | Pumping | Untested | |
        | Sibilance | Untested | |
        | Music/ads | Untested | |
        | Toggle artifact | Untested | |
        | Reference comparison | Untested | |
        | Fatigue after 10 minutes | Untested | |
        | Overall recommendation | Untested | |

        """
    }
}
