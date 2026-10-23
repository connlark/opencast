/// Deferred-not-failed kinds: retry sweeps treat these as queued for a
/// later probe rather than terminal failures.
/// - `capExceeded`: typed daily-cap denial — re-probed on a later foreground
///   session (a transcription backlog can legitimately hit the per-key cap).
/// - `insufficientSeconds`: typed pay-gate 402 from the Chapters & Summary
///   worker only (ad analysis is not pay-gated) — the account cannot cover
///   the run's charge; re-probed on the foreground session probe AND when
///   the shared transcription balance increases (H8).
///
/// The remaining ad-analysis kinds are terminal and exist so the episode
/// card can say why a run failed after a relaunch. Raw values persist; an
/// older build reads an unknown one as nil, i.e. generic.
enum EpisodeAnalysisFailureKind: String {
    case generic
    case capExceeded
    case insufficientSeconds
    /// The service or one of its dependencies could not be reached or read.
    case serviceUnavailable
    /// The model call or the run's execution deadline ran out.
    case timedOut
    /// The worker lost the job, or the app's run did not survive a relaunch.
    case interrupted
    /// The model's ad boundaries failed validation after every repair.
    case validationExhausted
}
