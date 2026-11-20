nonisolated struct PlaylistOrganizerRun: Sendable {
    var outcome: PlaylistOrganizerOutcome
    /// The last input sent; nil when building failed.
    var input: PlaylistOrganizerInput?
    /// The whole call, retries included.
    var elapsed: Duration
    /// The answering turn's usage.
    var usage: TranscriptIntelligenceUsage?
    var attempts: Int
    var rawProposals: [PlaylistProposal]
    var failure: TranscriptIntelligenceFailure?
    var retriedFailures: [TranscriptIntelligenceFailure] = []
}
