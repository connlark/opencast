import OpenCastAnalysis
import OpenCastAnalysisProviders

/// How far one device ad-detection run has come, in steps: each window's
/// first request, plus each corrective request the run has needed so far.
/// A step is done once a reply answers it, sent now or kept from an earlier
/// attempt of the same run.
nonisolated struct AdAnalysisRunProgress: Sendable, Hashable {
    private(set) var completed = 0
    private(set) var total: Int
    /// The longest one step can take before it gives up: the model's
    /// per-call timeout for each send a window's first request may make,
    /// plus the longest pause between them. Progress paces its creep inside
    /// a step over this, so a slow step never reaches its end early.
    let stepBudgetSeconds: Double
    private var answered: Set<AnalysisProviderRequest.Purpose> = []
    private var repairs: Set<Int> = []
    private let windowCount: Int

    /// `model` is the entry the run uses; without one, the slowest entry
    /// the baked bundle qualifies for ad detection.
    init(windowCount: Int, model: AnalysisModelEntry? = nil) {
        self.windowCount = max(windowCount, 1)
        total = self.windowCount
        stepBudgetSeconds = Self.stepBudgetSeconds(
            perCallTimeoutSeconds: model?.perCallTimeoutSeconds ?? Self.bakedPerCallTimeoutSeconds
        )
    }

    /// A window's first request makes up to two sends with at most a
    /// 10 s pause between them (the pipeline's attempt and backoff bounds).
    static func stepBudgetSeconds(perCallTimeoutSeconds: Int) -> Double {
        Double(max(perCallTimeoutSeconds, 1) * 2 + 10)
    }

    static let defaultStepBudgetSeconds = stepBudgetSeconds(perCallTimeoutSeconds: bakedPerCallTimeoutSeconds)

    private static let bakedPerCallTimeoutSeconds = AnalysisPolicyBundle.baked.features.adDetection.qualifiedModels
        .map(\.perCallTimeoutSeconds)
        .max() ?? 120

    /// Counts one send of `purpose`; `answered` when a reply came back.
    mutating func note(_ purpose: AnalysisProviderRequest.Purpose, answered isAnswered: Bool) {
        if case .adRepair(let index) = purpose {
            repairs.insert(index)
        }
        if isAnswered {
            answered.insert(purpose)
        }
        total = windowCount + repairs.count
        completed = min(answered.count, total)
    }

    /// Feeds a run's sends into its progress; a send the run cancelled
    /// counts for nothing.
    struct SendObserver: AnalysisProviderSendObserver {
        let onSend: @Sendable (AnalysisProviderRequest.Purpose, Bool) -> Void

        func record(_ send: AnalysisProviderSendRecord) {
            guard !send.cancelled else { return }
            onSend(send.purpose, send.failure == nil)
        }
    }
}
