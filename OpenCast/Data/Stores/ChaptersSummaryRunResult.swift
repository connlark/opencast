import OpenCastAnalysis

enum ChaptersSummaryRunResult {
    /// The store installs the document, then hands the completion back to
    /// the producer to close the run.
    case completed(EpisodeTranscriptAnalysisAPIResponse, ChaptersSummaryRunCompletion)
    case failed(ChaptersSummaryRunFailure)
    /// The run stays dispatched and resumes under the same id.
    case expired
    case cancelled
}

nonisolated struct ChaptersSummaryRunCompletion: Sendable, Equatable {
    let runID: String
    let outcome: AnalysisOutcome
    let background: Bool
}

nonisolated struct ChaptersSummaryRunFailure: Sendable, Equatable {
    let kind: EpisodeAnalysisFailureKind
    let message: String
}
