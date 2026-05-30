import Foundation

struct ListeningPackSummary: Codable {
    var formatVersion: Int
    var inputPath: String
    var reviewWarnings: [String]
    var readiness: ListeningPackReadiness
    var files: [String]
    var dry: AudioMetricsSummary
    var boosted: AudioMetricsSummary
    var toggle: AudioMetricsSummary
    var dryToBoosted: ComparisonSummary
    var toggleArtifacts: ToggleArtifactSummary
    var reference: AudioMetricsSummary?
    var dryToReference: ComparisonSummary?
    var boostedToReference: ComparisonSummary?
    var referenceAlignment: ReferenceAlignmentMetrics?
    var alignedDry: AudioMetricsSummary?
    var alignedBoosted: AudioMetricsSummary?
    var alignedReference: AudioMetricsSummary?
    var alignedDryToReference: ComparisonSummary?
    var alignedBoostedToReference: ComparisonSummary?

    init(result: ListeningPackResult, inputURL: URL) {
        formatVersion = 1
        inputPath = inputURL.path
        reviewWarnings = [
            "Metrics are an automated lab aid only; human listening notes are still required before release.",
            "Reference alignment is approximate and must not be treated as proof of perceptual equivalence."
        ]
        readiness = ListeningPackReadiness()
        files = Self.files(for: result)
        dry = AudioMetricsSummary(result.boostedResult.inputMetrics)
        boosted = AudioMetricsSummary(result.boostedResult.outputMetrics)
        toggle = AudioMetricsSummary(result.toggleMetrics)
        dryToBoosted = ComparisonSummary(result.boostedResult.comparisonMetrics)
        toggleArtifacts = ToggleArtifactSummary(result.toggleArtifactMetrics)
        reference = result.referenceMetrics.map(AudioMetricsSummary.init)
        dryToReference = result.dryReferenceComparison.map(ComparisonSummary.init)
        boostedToReference = result.boostedReferenceComparison.map(ComparisonSummary.init)
        referenceAlignment = result.referenceAlignment?.metrics
        alignedDry = result.referenceAlignment.map { AudioMetricsSummary($0.alignedDryMetrics) }
        alignedBoosted = result.referenceAlignment.map { AudioMetricsSummary($0.alignedBoostedMetrics) }
        alignedReference = result.referenceAlignment.map { AudioMetricsSummary($0.alignedReferenceMetrics) }
        alignedDryToReference = result.referenceAlignment.map {
            ComparisonSummary($0.alignedDryReferenceComparison)
        }
        alignedBoostedToReference = result.referenceAlignment.map {
            ComparisonSummary($0.alignedBoostedReferenceComparison)
        }
    }

    private static func files(for result: ListeningPackResult) -> [String] {
        var files = [
            "dry.wav",
            "boosted.wav",
            "toggle.wav",
            "dry_metrics.json",
            "boosted_metrics.json",
            "toggle_metrics.json",
            "toggle_artifacts.json",
            "comparison.json",
            "boosted_timeline.csv",
            "listening_notes.md",
            "summary.json"
        ]

        if result.referenceAudio != nil {
            files.append(contentsOf: [
                "reference.wav",
                "reference_metrics.json",
                "dry_reference_comparison.json",
                "boosted_reference_comparison.json"
            ])
        }

        if result.referenceAlignment != nil {
            files.append(contentsOf: [
                "reference_alignment.json",
                "aligned_dry.wav",
                "aligned_boosted.wav",
                "aligned_reference.wav",
                "aligned_dry_metrics.json",
                "aligned_boosted_metrics.json",
                "aligned_reference_metrics.json",
                "aligned_dry_reference_comparison.json",
                "aligned_boosted_reference_comparison.json"
            ])
        }

        return files.sorted()
    }
}

struct ListeningPackReadiness: Codable {
    var metricOnly: Bool
    var humanListeningRequired: Bool
    var deviceRuntimeRequired: Bool
    var releaseApproved: Bool

    init(
        metricOnly: Bool = true,
        humanListeningRequired: Bool = true,
        deviceRuntimeRequired: Bool = true,
        releaseApproved: Bool = false
    ) {
        self.metricOnly = metricOnly
        self.humanListeningRequired = humanListeningRequired
        self.deviceRuntimeRequired = deviceRuntimeRequired
        self.releaseApproved = releaseApproved
    }
}

struct AudioMetricsSummary: Codable {
    var durationSeconds: Double
    var integratedLUFS: Double?
    var truePeakDBTP: Double?
    var rmsDBFS: Double?
    var clippedSampleCount: Int
    var nanInfSampleCount: Int

    init(_ metrics: AudioMetrics) {
        durationSeconds = metrics.durationSeconds
        integratedLUFS = metrics.integratedLUFS
        truePeakDBTP = metrics.truePeakDBTP
        rmsDBFS = metrics.rmsDBFS
        clippedSampleCount = metrics.clippedSampleCount
        nanInfSampleCount = metrics.nanInfSampleCount
    }
}

struct ComparisonSummary: Codable {
    var loudnessDeltaLU: Double?
    var truePeakDeltaDB: Double?
    var rmsDeltaDB: Double?

    init(_ comparison: ComparisonMetrics) {
        loudnessDeltaLU = comparison.loudnessDeltaLU
        truePeakDeltaDB = comparison.truePeakDeltaDB
        rmsDeltaDB = comparison.rmsDeltaDB
    }
}

struct ToggleArtifactSummary: Codable {
    var transitionCount: Int
    var maxFileAdjacentStep: Double
    var maxBoundaryAdjacentStep: Double
    var p95BoundaryAdjacentStep: Double?
    var maxBoundaryToFileStepRatio: Double?

    init(_ metrics: ToggleArtifactMetrics) {
        transitionCount = metrics.transitionCount
        maxFileAdjacentStep = metrics.maxFileAdjacentStep
        maxBoundaryAdjacentStep = metrics.maxBoundaryAdjacentStep
        p95BoundaryAdjacentStep = metrics.p95BoundaryAdjacentStep
        maxBoundaryToFileStepRatio = metrics.maxBoundaryToFileStepRatio
    }
}
