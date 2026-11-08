import OpenCastAnalysisProviders

/// The key sheet's last Test as one value, so a new Test or an edit clears
/// whether the key was accepted and what Google said about its tier together.
struct AnalysisKeyTestState {
    /// Bumped by every edit, sync change, Save, Remove and Test. A result
    /// stamped with an older generation describes a draft that is gone.
    private(set) var generation = 0
    private(set) var isTesting = false
    private(set) var result: AnalysisKeyTestResult?
    /// What Google said about the tested key's tier, apart from whether it
    /// accepted the key, with the digest of the key it was given for.
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

    /// Begins a Test of `key` and returns its generation. A key that could
    /// not be read has nothing to test: that is the result, and it returns
    /// `nil`. The last result goes first either way, so a failure here never
    /// reads under what Google said about an earlier Test.
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
