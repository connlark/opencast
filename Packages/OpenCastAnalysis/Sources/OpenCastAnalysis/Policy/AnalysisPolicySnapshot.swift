import Foundation

public enum AnalysisPolicySource: Sendable, Equatable {
    case baked
    /// A downloaded, verified bundle, last confirmed by the server at the date.
    case downloaded(confirmedAt: Date)
}

public struct AnalysisPolicySnapshot: Sendable, Equatable {
    public let bundle: AnalysisPolicyBundle
    public let source: AnalysisPolicySource
    /// `nil` when a downloaded bundle is active, and also when the baked copy is active only
    /// because it is the newest.
    public let fallbackReason: AnalysisPolicyRejection?
    /// Set even while an earlier downloaded bundle stays active.
    public let lastRefreshFailure: AnalysisPolicyRejection?

    public init(
        bundle: AnalysisPolicyBundle,
        source: AnalysisPolicySource,
        fallbackReason: AnalysisPolicyRejection?,
        lastRefreshFailure: AnalysisPolicyRejection?
    ) {
        self.bundle = bundle
        self.source = source
        self.fallbackReason = fallbackReason
        self.lastRefreshFailure = lastRefreshFailure
    }

    public func adDetection(provider: AnalysisProvider) -> AdDetectionAnalysisPolicy? {
        let feature = bundle.features.adDetection
        return feature.qualifiedModels.first { $0.provider == provider }.map {
            AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0)
        }
    }

    public func chaptersSummary(provider: AnalysisProvider) -> ChaptersSummaryAnalysisPolicy? {
        let feature = bundle.features.chaptersSummary
        return feature.allowedModels.first { $0.provider == provider }.map {
            AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0)
        }
    }

    /// Never `nil` for an accepted bundle: validation requires the entry.
    public var trialAdDetection: AdDetectionAnalysisPolicy? {
        let feature = bundle.features.adDetection
        return feature.qualifiedModels
            .first { $0.provider == .google && $0.modelID == bundle.trial.modelID }
            .map { AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0) }
    }
}
