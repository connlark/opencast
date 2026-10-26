import Foundation

/// Where the active bundle came from.
public enum AnalysisPolicySource: Sendable, Equatable {
    /// The copy compiled into this build.
    case baked
    /// A downloaded, verified bundle, last confirmed by the server at the date.
    case downloaded(confirmedAt: Date)
}

/// The policy the app runs under right now, and why.
public struct AnalysisPolicySnapshot: Sendable, Equatable {
    public let bundle: AnalysisPolicyBundle
    public let source: AnalysisPolicySource
    /// Why the baked copy is active instead of a downloaded bundle. `nil` when
    /// a downloaded bundle is active, or when the baked copy is simply the
    /// newest (the server's bundle is not newer than the build's).
    public let fallbackReason: AnalysisPolicyRejection?
    /// The outcome of the latest refresh when it failed, even if an earlier
    /// downloaded bundle is still active.
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

    /// The ad-detection policy for a provider, or `nil` when the bundle has no
    /// qualified entry for it.
    public func adDetection(provider: AnalysisProvider) -> AdDetectionAnalysisPolicy? {
        let feature = bundle.features.adDetection
        return feature.qualifiedModels.first { $0.provider == provider }.map {
            AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0)
        }
    }

    /// The Chapters & Summary policy for a provider, or `nil` when the bundle
    /// has no allowed entry for it (the provider is hidden for Chapters).
    public func chaptersSummary(provider: AnalysisProvider) -> ChaptersSummaryAnalysisPolicy? {
        let feature = bundle.features.chaptersSummary
        return feature.allowedModels.first { $0.provider == provider }.map {
            AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0)
        }
    }

    /// The trial's model as an ad-detection policy. Validation guarantees the
    /// entry exists in every accepted bundle.
    public var trialAdDetection: AdDetectionAnalysisPolicy? {
        let feature = bundle.features.adDetection
        return feature.qualifiedModels
            .first { $0.provider == .google && $0.modelID == bundle.trial.modelID }
            .map { AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0) }
    }
}
