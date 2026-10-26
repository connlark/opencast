import OpenCastAnalysis

/// How a Chapters & Summary run ended, in the store's terms.
enum ChaptersSummaryRunResult {
    /// The store installs the document, then hands the completion back to
    /// the producer to close the run.
    case completed(EpisodeTranscriptAnalysisAPIResponse, ChaptersSummaryRunCompletion)
    case failed(ChaptersSummaryRunFailure)
    /// The background card expired: the run stays dispatched and resumes
    /// with the same id at the next launch or foreground return.
    case expired
    case cancelled
}

/// What closing a completed run needs once its document is installed.
nonisolated struct ChaptersSummaryRunCompletion: Sendable, Equatable {
    let runID: String
    let outcome: AnalysisOutcome
    let background: Bool
}

/// A failed run's persisted kind and its message. The message is built from
/// closed-vocabulary codes only, never from a provider body.
nonisolated struct ChaptersSummaryRunFailure: Sendable, Equatable {
    let kind: EpisodeAnalysisFailureKind
    let message: String
}
