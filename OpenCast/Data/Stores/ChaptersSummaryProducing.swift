import Foundation
import OpenCastAnalysis
import SwiftData

/// Runs one Chapters & Summary analysis end to end: route, run record,
/// transport and the continued-processing session. The store owns records,
/// documents and cancellation; cancelling the calling task cancels the run.
protocol ChaptersSummaryProducing: AnyObject {
    func run(_ request: ChaptersSummaryRunRequest, modelContext: ModelContext) async -> ChaptersSummaryRunResult
    /// Closes a completed run once its document is installed. Until then the
    /// run stays dispatched with its reply kept, so a process that dies
    /// between the answer and the document resumes without another send.
    func finish(_ completion: ChaptersSummaryRunCompletion)
    /// Closes a completed run whose answer this build cannot install (its
    /// contract is not the pinned one) as failed with `code`.
    func fail(_ completion: ChaptersSummaryRunCompletion, code: AnalysisFailureCode)
    /// Closes a run whose document was installed before the process stopped
    /// short of ``finish(_:)``. Does nothing to a run already ended.
    func finishInstalled(runID: String)
    /// Closes a dispatched run that will never resume (its transcript or
    /// policy changed, it outlived the resume window, or its analysis was
    /// deleted), counting what it billed first. A run stopped for its key's
    /// removal closes as needing a key. Does nothing to a run already ended.
    func abandon(runID: String, modelContext: ModelContext)
    /// Counts the usage of ended direct runs whose usage never saved (the
    /// save failed, or the process stopped first), once by run id.
    func recordUnaccountedUsage(modelContext: ModelContext)
    /// Marks the open run `runID` to end as needing a key, its usage counted
    /// first, when its cancellation (which the caller sends next) closes
    /// it: the listener removed its key for `provider` in AI Services. False,
    /// and nothing marked, for a trial run, a run on another provider or a
    /// run already ended.
    func stopForKeyRemoval(runID: String, provider: AnalysisProvider) -> Bool
}

/// The dispatched run a `.running` Chapters & Summary record resumes. The
/// producer checks the rest of the run's identity (route, provider, model,
/// policy) against a fresh resolution before reusing anything.
nonisolated struct ChaptersSummaryDispatchedRun: Sendable, Equatable {
    let runID: String
    let transcriptFingerprint: String
    let startedAt: Date
}
