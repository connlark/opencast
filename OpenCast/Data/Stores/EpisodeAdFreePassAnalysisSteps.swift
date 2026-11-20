nonisolated struct EpisodeAdFreePassAnalysisSteps: Equatable, Sendable {
    let completed: Int
    let total: Int
    /// How long the current step may take before it gives up.
    let stepBudgetSeconds: Double
    /// A change means a handover: the steps start over.
    let attemptID: String?
    let isFreeTierTrial: Bool

    init(
        completed: Int,
        total: Int,
        stepBudgetSeconds: Double = AdAnalysisRunProgress.defaultStepBudgetSeconds,
        attemptID: String? = nil,
        isFreeTierTrial: Bool = false
    ) {
        self.total = max(total, 1)
        self.completed = min(max(completed, 0), self.total)
        self.stepBudgetSeconds = max(stepBudgetSeconds, 1)
        self.attemptID = attemptID
        self.isFreeTierTrial = isFreeTierTrial
    }

    /// Adds the step still to come: a window counts as answered before its repair is known, so
    /// without it a slow repair would sit at the band's end.
    init(_ progress: AdAnalysisRunProgress) {
        self.init(
            completed: progress.completed,
            total: progress.total + 1,
            stepBudgetSeconds: progress.stepBudgetSeconds,
            attemptID: progress.attemptID,
            isFreeTierTrial: progress.isFreeTierTrial
        )
    }

    /// Before the run knows its steps: one window and the step to come.
    static let unknownRun = EpisodeAdFreePassAnalysisSteps(completed: 0, total: 2)
}
