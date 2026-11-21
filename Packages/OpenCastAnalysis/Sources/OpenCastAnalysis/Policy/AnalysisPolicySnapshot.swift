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

    /// The provider's default entry.
    public func adDetection(provider: AnalysisProvider) -> AdDetectionAnalysisPolicy? {
        let feature = bundle.features.adDetection
        return feature.qualifiedModels.first { $0.provider == provider }.map {
            AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0)
        }
    }

    /// The provider's default entry.
    public func chaptersSummary(provider: AnalysisProvider) -> ChaptersSummaryAnalysisPolicy? {
        let feature = bundle.features.chaptersSummary
        return feature.allowedModels.first { $0.provider == provider }.map {
            AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0)
        }
    }

    public func adDetection(model: AnalysisModelIdentity) -> AdDetectionAnalysisPolicy? {
        let feature = bundle.features.adDetection
        return modelEntries(for: .adDetection, provider: model.provider).first { $0.modelID == model.modelID }.map {
            AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0)
        }
    }

    public func chaptersSummary(model: AnalysisModelIdentity) -> ChaptersSummaryAnalysisPolicy? {
        let feature = bundle.features.chaptersSummary
        return modelEntries(for: .chaptersSummary, provider: model.provider).first { $0.modelID == model.modelID }.map {
            AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0)
        }
    }

    /// The provider's default entry first, then its additional entries.
    public func modelEntries(for feature: AnalysisFeature, provider: AnalysisProvider) -> [AnalysisModelEntry] {
        let entries = switch feature {
        case .adDetection: bundle.features.adDetection.qualifiedModels + bundle.features.adDetection.additionalModels
        case .chaptersSummary: bundle.features.chaptersSummary.allowedModels + bundle.features.chaptersSummary.additionalModels
        }
        return entries.filter { $0.provider == provider }
    }

    /// Never `nil` for an accepted bundle: validation requires the entry.
    public var trialAdDetection: AdDetectionAnalysisPolicy? {
        let feature = bundle.features.adDetection
        return feature.qualifiedModels
            .first { $0.provider == .google && $0.modelID == bundle.trial.modelID }
            .map { AnalysisPolicy(bundleVersion: bundle.bundleVersion, source: source, settings: feature, model: $0) }
    }
}
