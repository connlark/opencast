import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData

/// Runs Chapters & Summary on the device: resolves the route, writes the
/// run record before the first send, builds the run's transport and runs
/// the package's pipeline inside the app-wide continued-processing session,
/// so a run can finish in the background under the system's progress card.
/// A card the system refuses runs in the foreground only.
final class ChaptersSummaryRunProducer: ChaptersSummaryProducing {
    struct Dependencies {
        var resolve: (_ resumingRunID: String?) async -> AnalysisRouteResolution
        var runs: AnalysisRunRecordStore
        var makeTransport: (
            _ resolution: AnalysisRouteResolution,
            _ runID: String,
            _ observer: any AnalysisProviderSendObserver
        ) throws(AnalysisTransportFactoryError) -> any AnalysisProviderTransport
        var session: AnalysisExecutionSession
        /// Adds a direct run's billed totals so far to the listener's
        /// usage under its run id (only their growth counts); false when the
        /// save failed.
        var recordUsage: (
            _ provider: AnalysisProvider,
            _ inputTokens: Int,
            _ outputTokens: Int,
            _ runID: String,
            _ modelContext: ModelContext
        ) -> Bool
        var presentKeyRequired: (AnalysisKeyRequiredReason) -> Void
        /// The trial refused for its units or its month: the cached status
        /// is stale.
        var refreshTrialStatus: () -> Void
        /// Why a direct run lost its listener's key mid-run (removed,
        /// replaced or unreadable), when a send found it gone.
        var keyRemoval: (_ runID: String) -> AnalysisKeyRequiredReason? = { _ in nil }
        var clock: any AnalysisClock = AnalysisSystemClock()
    }

    private let dependencies: Dependencies
    /// Open runs whose key the listener removed in AI Services: their
    /// cancellation closes them as needing a key.
    private var keyRemovedRunIDs: Set<String> = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func run(_ request: ChaptersSummaryRunRequest, modelContext: ModelContext) async -> ChaptersSummaryRunResult {
        let runs = dependencies.runs
        let resolution = await dependencies.resolve(request.isResume ? request.runID : nil)
        guard !Task.isCancelled else {
            return cancel(request, modelContext: modelContext)
        }
        if let reason = resolution.keyRequiredReason {
            if request.isResume {
                closeCancelled(runID: request.runID, modelContext: modelContext)
            }
            return keyRequired(reason, request: request)
        }
        // A resume continues only under the route, model and policy it
        // started with, and on the same request: a reply kept under one
        // bundle or for one transcript is never validated under another.
        // Anything else needs a fresh Generate.
        if request.isResume,
           resolution.resumingRunID != request.runID
            || runs.record(id: request.runID)?.inputDigest != request.inputDigest {
            closeCancelled(runID: request.runID, modelContext: modelContext)
            return .failed(ChaptersSummaryFailureMapping.interrupted)
        }
        guard let routePolicy = resolution.policy, let policy = routePolicy.chaptersSummary else {
            return keyRequired(.noKey, request: request)
        }

        if !request.isResume {
            do {
                try runs.begin(AnalysisRunRecord(
                    id: request.runID,
                    feature: .chaptersSummary,
                    episodeID: request.episodeID,
                    podcastID: request.podcastID,
                    transcriptFingerprint: request.transcriptFingerprint,
                    inputDigest: request.inputDigest,
                    resolution: resolution,
                    policy: routePolicy
                ))
            } catch {
                // Nothing is sent without a record to resume from.
                return .failed(ChaptersSummaryFailureMapping.runRecordUnavailable)
            }
        }

        let sends = AnalysisProviderSendLog()
        let transport: any AnalysisProviderTransport
        do {
            transport = try dependencies.makeTransport(
                resolution,
                request.runID,
                AnalysisSendObservers(observers: [runs.observer(runID: request.runID), sends])
            )
        } catch {
            closeCancelled(runID: request.runID, modelContext: modelContext)
            switch error {
            case .keyRequired(let reason):
                return keyRequired(reason, request: request)
            case .configuration:
                return .failed(ChaptersSummaryFailureMapping.providerConfiguration)
            }
        }

        let runner = AnalysisRunner(transport: transport, clock: dependencies.clock)
        let analysisRequest = request.analysisRequest
        let execution = await dependencies.session.run(
            subtitle: request.episodeTitle,
            expectedSeconds: policy.model.runBudgetSeconds
        ) {
            await runner.generateChapters(analysisRequest, policy: policy)
        }
        // A delete or a nuke cancels the caller while the card may also be
        // expiring; cancellation wins, so a stopped run is never resumed.
        guard !Task.isCancelled else {
            return cancel(request, modelContext: modelContext)
        }

        switch execution {
        case .expired:
            runs.markExpired(runID: request.runID)
            return .expired
        case .finished(let outcome, let background):
            return finish(
                outcome,
                background: background,
                sends: sends.sends,
                request: request,
                modelContext: modelContext
            )
        }
    }

    func finish(_ completion: ChaptersSummaryRunCompletion) {
        dependencies.runs.finish(
            runID: completion.runID,
            outcome: completion.outcome,
            listenerFailure: nil,
            background: completion.background
        )
    }

    func fail(_ completion: ChaptersSummaryRunCompletion, code: AnalysisFailureCode) {
        dependencies.runs.finish(
            runID: completion.runID,
            outcome: .failed(AnalysisFailure(feature: .chaptersSummary, code: code, status: 0)),
            listenerFailure: nil,
            background: completion.background
        )
    }

    func finishInstalled(runID: String) {
        dependencies.runs.finishInstalled(runID: runID)
    }

    func abandon(runID: String, modelContext: ModelContext) {
        closeCancelled(runID: runID, modelContext: modelContext)
    }

    func stopForKeyRemoval(runID: String, provider: AnalysisProvider) -> Bool {
        guard let record = dependencies.runs.record(id: runID),
              record.route == .direct,
              record.provider == provider,
              record.state == .dispatched || record.state == .expired
        else {
            return false
        }
        keyRemovedRunIDs.insert(runID)
        return true
    }

    /// Ended direct runs whose usage never saved (the save failed, or the
    /// process stopped first) are counted, once by run id.
    func recordUnaccountedUsage(modelContext: ModelContext) {
        for run in dependencies.runs.unaccountedDirectRuns(feature: .chaptersSummary) {
            recordUsage(runID: run.id, modelContext: modelContext)
        }
    }

    private func finish(
        _ outcome: AnalysisOutcome,
        background: Bool,
        sends: [AnalysisProviderSendRecord],
        request: ChaptersSummaryRunRequest,
        modelContext: ModelContext
    ) -> ChaptersSummaryRunResult {
        let runs = dependencies.runs
        switch outcome {
        case .chaptersSummary(let response):
            recordUsage(runID: request.runID, modelContext: modelContext)
            let completion = ChaptersSummaryRunCompletion(runID: request.runID, outcome: outcome, background: background)
            guard let decoded = try? EpisodeTranscriptAnalysisJSONCoding.decoder().decode(
                EpisodeTranscriptAnalysisAPIResponse.self,
                from: Data(response.jsonText.utf8)
            ) else {
                fail(completion, code: .unsupportedSchemaVersion)
                return .failed(ChaptersSummaryFailureMapping.unexpectedContract)
            }
            return .completed(decoded, completion)
        case .failed(let failure) where failure.code == .cancelled:
            return cancel(request, modelContext: modelContext)
        case .failed(let failure):
            recordUsage(runID: request.runID, modelContext: modelContext)
            let listenerFailure = AnalysisProviderFailure.resolve(outcome, sends: sends)
            runs.finish(runID: request.runID, outcome: outcome, listenerFailure: listenerFailure, background: background)
            // A key removed, replaced or unreadable mid-run ends the run as
            // needing a key, with no key screen: the listener is where keys
            // are added.
            if let reason = dependencies.keyRemoval(request.runID) ?? (listenerFailure == .keyRequired ? .noKey : nil) {
                return .failed(ChaptersSummaryFailureMapping.failure(keyRequired: reason))
            }
            let mapped = ChaptersSummaryFailureMapping.failure(failure, listenerFailure: listenerFailure)
            if let reason = mapped.kind.keyRequiredReason {
                if reason == .trialExhausted || reason == .trialPaused {
                    dependencies.refreshTrialStatus()
                }
                if request.startedByListener {
                    dependencies.presentKeyRequired(reason)
                }
            }
            return .failed(mapped)
        case .adDetection:
            closeCancelled(runID: request.runID, modelContext: modelContext)
            return .failed(ChaptersSummaryFailureMapping.unexpectedContract)
        }
    }

    private func cancel(_ request: ChaptersSummaryRunRequest, modelContext: ModelContext) -> ChaptersSummaryRunResult {
        let keyRemoved = keyRemovedRunIDs.contains(request.runID)
        closeCancelled(runID: request.runID, modelContext: modelContext)
        return keyRemoved ? .failed(ChaptersSummaryFailureMapping.failure(keyRequired: .noKey)) : .cancelled
    }

    /// Every cancellation of a run that may have been billed: its usage is
    /// counted before the record's terminal state is written. A run stopped
    /// for its key's removal fails as a send that found the key gone fails
    /// it; a run already ended keeps its end.
    private func closeCancelled(runID: String, modelContext: ModelContext) {
        let keyRemoved = keyRemovedRunIDs.remove(runID) != nil
        recordUsage(runID: runID, modelContext: modelContext)
        let runs = dependencies.runs
        guard let state = runs.record(id: runID)?.state, state == .dispatched || state == .expired else {
            return
        }
        if keyRemoved {
            runs.finish(runID: runID, outcome: .failed(Self.keyRemovedFailure), listenerFailure: .keyRequired, background: nil)
        } else {
            runs.markCancelled(runID: runID)
        }
    }

    /// The Chapters pipeline's failure when the key guard refuses a send
    /// (rejected with status 0), so a run stopped for an in-app removal
    /// keeps the same record.
    private static let keyRemovedFailure = AnalysisFailure(feature: .chaptersSummary, code: .providerRejected, status: 502)

    /// Every key-required exit, at resolution, at the policy or at the
    /// transport: a listener's Generate shows the key screen, a resume never
    /// does.
    private func keyRequired(_ reason: AnalysisKeyRequiredReason, request: ChaptersSummaryRunRequest) -> ChaptersSummaryRunResult {
        if request.startedByListener {
            dependencies.presentKeyRequired(reason)
        }
        return .failed(ChaptersSummaryFailureMapping.failure(keyRequired: reason))
    }

    /// Counts a run on the listener's key from its record's totals, which
    /// cover every execution of the run id, before the record's terminal
    /// state is written; the usage store adds only their growth. The record
    /// says whether its usage is saved, so a failed save is counted at the
    /// next load. Trial runs are opencast's bill, not the listener's.
    private func recordUsage(runID: String, modelContext: ModelContext) {
        let runs = dependencies.runs
        guard let record = runs.record(id: runID),
              record.route == .direct,
              record.inputTokens > 0 || record.outputTokens > 0
        else {
            return
        }
        let saved = dependencies.recordUsage(
            record.provider,
            Int(clamping: record.inputTokens),
            Int(clamping: record.outputTokens),
            runID,
            modelContext
        )
        if saved {
            runs.markUsageRecorded(runID: runID)
        } else if record.usageRecorded == true {
            // Counted before, but this growth was not saved.
            runs.update(runID: runID) { $0.usageRecorded = false }
        }
    }
}
