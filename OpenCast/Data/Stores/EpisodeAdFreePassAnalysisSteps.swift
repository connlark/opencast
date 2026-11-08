/// How far an episode's ad detection has come, in steps, for its progress:
/// each window's first request, each corrective request the run has needed
/// so far, and while the run is going one more step still to come, so the
/// band's end is reached only when the run ends. `stepBudgetSeconds` is how
/// long the current step may take before it gives up.
nonisolated struct EpisodeAdFreePassAnalysisSteps: Equatable, Sendable {
    let completed: Int
    let total: Int
    let stepBudgetSeconds: Double
    /// The run record these steps belong to. A change means a handover: the
    /// steps start over, and each mapper rebases on its own position.
    let attemptID: String?
    /// The run uses the trial service because Google named the key free tier.
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

    /// A running run's steps: its own, plus the one still to come. A
    /// window whose answer needs a repair counts as answered before the
    /// repair is known, so without the pending step a slow repair would
    /// sit at the band's end.
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
