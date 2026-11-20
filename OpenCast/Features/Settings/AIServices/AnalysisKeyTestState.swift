import OpenCastAnalysisProviders

/// One value, so a new Test or an edit clears the acceptance and the tier answer together.
struct AnalysisKeyTestState {
    /// Bumped by every edit, sync change, Save, Remove and Test. A result
    /// stamped with an older generation describes a draft that is gone.
    private(set) var generation = 0
    private(set) var isTesting = false
    private(set) var result: AnalysisKeyTestResult?
    private(set) var tier: AnalysisKeyTierStore.Answer?

    var isFreeTier: Bool {
        tier?.result == .freeTier
    }

    mutating func invalidate() {
        generation += 1
        isTesting = false
        result = nil
        tier = nil
    }

    /// Clears the last result first, so a failure never reads under an earlier tier answer.
    mutating func start(key: AnalysisProviderKey?) -> Int? {
        invalidate()
        guard key != nil else {
            result = .failed(.requestRejected)
            return nil
        }
        isTesting = true
        return generation
    }

    /// Lands a finished Test; `false` when its draft is gone.
    mutating func finish(
        _ result: AnalysisKeyTestResult,
        tier: AnalysisKeyTierStore.Answer,
        generation: Int
    ) -> Bool {
        guard generation == self.generation else {
            return false
        }
        self.result = result
        self.tier = tier
        isTesting = false
        return true
    }
}
