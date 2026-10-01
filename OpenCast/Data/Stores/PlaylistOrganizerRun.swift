/// One request with its measurements, for the evaluation runner's report.
nonisolated struct PlaylistOrganizerRun: Sendable {
    var outcome: PlaylistOrganizerOutcome
    /// The last input sent; nil when building failed.
    var input: PlaylistOrganizerInput?
    /// The whole call, retries included.
    var elapsed: Duration
    /// The answering turn's usage.
    var usage: TranscriptIntelligenceUsage?
    /// Model turns made.
    var attempts: Int
    /// The model's answer before validation.
    var rawProposals: [PlaylistProposal]
    /// The failure behind a non-proposal outcome.
    var failure: TranscriptIntelligenceFailure?
    /// The failures retried on the way to the outcome, in order. A decline
    /// the listener never saw still counts toward the decline rate.
    var retriedFailures: [TranscriptIntelligenceFailure] = []
}
