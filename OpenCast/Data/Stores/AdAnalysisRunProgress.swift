import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Steps are each window's first request plus each corrective request so far. A step is done
/// once a reply answers it, sent now or kept from an earlier attempt of the same run.
nonisolated struct AdAnalysisRunProgress: Sendable, Hashable {
    private(set) var completed = 0
    private(set) var total: Int
    let stepBudgetSeconds: Double
    let attemptID: String?
    let isFreeTierTrial: Bool
    private var answered: Set<AnalysisProviderRequest.Purpose> = []
    private var repairs: Set<Int> = []
    private let windowCount: Int

    init(windowCount: Int, model: AnalysisModelEntry? = nil, attemptID: String? = nil, isFreeTierTrial: Bool = false) {
        self.attemptID = attemptID
        self.isFreeTierTrial = isFreeTierTrial
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

    struct SendObserver: AnalysisProviderSendObserver {
        let onSend: @Sendable (AnalysisProviderRequest.Purpose, Bool) -> Void

        func record(_ send: AnalysisProviderSendRecord) {
            guard !send.cancelled else { return }
            onSend(send.purpose, send.failure == nil)
        }
    }
}
