import Foundation
import OpenCastAnalysis
import SwiftData

/// The store owns records, documents and cancellation; cancelling the calling task cancels the
/// run.
protocol ChaptersSummaryProducing: AnyObject {
    func run(_ request: ChaptersSummaryRunRequest, modelContext: ModelContext) async -> ChaptersSummaryRunResult
    /// Call only once the document is installed: until then the run stays dispatched with its
    /// reply kept, so a process that dies in between resumes without another send.
    func finish(_ completion: ChaptersSummaryRunCompletion)
    func fail(_ completion: ChaptersSummaryRunCompletion, code: AnalysisFailureCode)
    func finishInstalled(runID: String)
    func abandon(runID: String, modelContext: ModelContext)
    func recordUnaccountedUsage(modelContext: ModelContext)
    /// Only marks the run: the caller cancels it next, and that closes it as needing a key. False
    /// for a trial run, a run on another provider or a run already ended.
    func stopForKeyRemoval(runID: String, provider: AnalysisProvider) -> Bool
}

nonisolated struct ChaptersSummaryDispatchedRun: Sendable, Equatable {
    let runID: String
    let transcriptFingerprint: String
    let startedAt: Date
}
