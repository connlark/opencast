import OpenCastAnalysis

/// The policy a resolved route runs under, for one feature.
nonisolated enum AnalysisRoutePolicy: Sendable, Equatable {
    case adDetection(AdDetectionAnalysisPolicy)
    case chaptersSummary(ChaptersSummaryAnalysisPolicy)

    var adDetection: AdDetectionAnalysisPolicy? {
        if case .adDetection(let policy) = self { policy } else { nil }
    }

    var chaptersSummary: ChaptersSummaryAnalysisPolicy? {
        if case .chaptersSummary(let policy) = self { policy } else { nil }
    }

    var bundleVersion: Int {
        switch self {
        case .adDetection(let policy): policy.bundleVersion
        case .chaptersSummary(let policy): policy.bundleVersion
        }
    }

    var source: AnalysisPolicySource {
        switch self {
        case .adDetection(let policy): policy.source
        case .chaptersSummary(let policy): policy.source
        }
    }

    var model: AnalysisModelEntry {
        switch self {
        case .adDetection(let policy): policy.model
        case .chaptersSummary(let policy): policy.model
        }
    }

    var revision: String {
        switch self {
        case .adDetection(let policy): policy.settings.revision
        case .chaptersSummary(let policy): policy.settings.revision
        }
    }
}
