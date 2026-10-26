import Foundation
import OpenCastAnalysis
import SwiftData
@testable import OpenCast

/// A Chapters & Summary producer the test scripts: each run answers the next
/// scripted result (a completed answer by default), optionally after a hold
/// the test releases or the run's cancellation ends. It plays the run-record
/// side too: a new run is dispatched until it finishes, expires into a
/// resumable run, or is abandoned.
@MainActor
final class FakeChaptersSummaryProducer: ChaptersSummaryProducing {
    var scripted: [ChaptersSummaryRunResult] = []
    var holdsRuns = false
    var policy = EpisodeTranscriptAnalysisContract.expectedPolicy
    private(set) var requests: [ChaptersSummaryRunRequest] = []
    private(set) var finished: [String] = []
    private(set) var finishedInstalled: [String] = []
    private(set) var failedRuns: [String] = []
    private(set) var unaccountedUsageSweeps = 0
    private(set) var abandoned: [String] = []
    private(set) var cancelledRunIDs: [String] = []
    /// What the store's dispatched-run lookup answers, by episode id.
    var dispatched: [String: ChaptersSummaryDispatchedRun] = [:]
    private var hold: CheckedContinuation<Void, Never>?

    var isHolding: Bool {
        hold != nil
    }

    func attach(to store: EpisodeTranscriptAnalysisStore) {
        store.producer = self
        store.dispatchedRunLookup = { [weak self] episodeID in
            self?.dispatched[episodeID]
        }
        store.openRunEpisodeIDs = { [weak self] in
            self.map { Array($0.dispatched.keys) } ?? []
        }
    }

    func run(_ request: ChaptersSummaryRunRequest, modelContext: ModelContext) async -> ChaptersSummaryRunResult {
        requests.append(request)
        if !request.isResume {
            dispatched[request.episodeID] = ChaptersSummaryDispatchedRun(
                runID: request.runID,
                transcriptFingerprint: request.transcriptFingerprint,
                startedAt: .now
            )
        }
        if holdsRuns {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    hold = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.release()
                }
            }
        }
        if Task.isCancelled {
            cancelledRunIDs.append(request.runID)
            dispatched[request.episodeID] = nil
            return .cancelled
        }
        let result = scripted.isEmpty
            ? .completed(
                Self.response(requestID: request.runID, policy: policy),
                ChaptersSummaryRunCompletion(runID: request.runID, outcome: Self.placeholderOutcome, background: false)
            )
            : scripted.removeFirst()
        switch result {
        case .expired, .completed:
            break
        case .failed, .cancelled:
            dispatched[request.episodeID] = nil
        }
        return result
    }

    func finish(_ completion: ChaptersSummaryRunCompletion) {
        finished.append(completion.runID)
        dispatched = dispatched.filter { $0.value.runID != completion.runID }
    }

    func fail(_ completion: ChaptersSummaryRunCompletion, code: AnalysisFailureCode) {
        failedRuns.append(completion.runID)
        dispatched = dispatched.filter { $0.value.runID != completion.runID }
    }

    func finishInstalled(runID: String) {
        finishedInstalled.append(runID)
        dispatched = dispatched.filter { $0.value.runID != runID }
    }

    func recordUnaccountedUsage(modelContext: ModelContext) {
        unaccountedUsageSweeps += 1
    }

    func abandon(runID: String, modelContext: ModelContext) {
        abandoned.append(runID)
        dispatched = dispatched.filter { $0.value.runID != runID }
    }

    /// The provider a dispatched run sends on with the listener's key;
    /// `nil` plays the trial.
    var directProvider: AnalysisProvider?

    func stopForKeyRemoval(runID: String, provider: AnalysisProvider) -> Bool {
        directProvider == provider && dispatched.values.contains { $0.runID == runID }
    }

    func release() {
        hold?.resume()
        hold = nil
    }

    static let placeholderOutcome = AnalysisOutcome.failed(
        AnalysisFailure(feature: .chaptersSummary, code: .cancelled, status: 0)
    )

    static func completed(requestID: String = "scripted", policy: String = EpisodeTranscriptAnalysisContract.expectedPolicy) -> ChaptersSummaryRunResult {
        .completed(
            response(requestID: requestID, policy: policy),
            ChaptersSummaryRunCompletion(runID: requestID, outcome: placeholderOutcome, background: false)
        )
    }

    static func response(
        requestID: String,
        policy: String = EpisodeTranscriptAnalysisContract.expectedPolicy,
        chapters: [EpisodeTranscriptAnalysisAPIChapter]? = nil,
        summary: EpisodeTranscriptAnalysisAPISummary?? = nil
    ) -> EpisodeTranscriptAnalysisAPIResponse {
        EpisodeTranscriptAnalysisAPIResponse(
            schemaVersion: 1,
            requestID: requestID,
            model: "gemini-3.8-flash",
            policy: policy,
            chapters: chapters ?? [
                EpisodeTranscriptAnalysisAPIChapter(
                    title: "Welcome",
                    startSegmentID: 0,
                    endSegmentID: 0,
                    startTime: 0,
                    endTime: 5,
                    confidence: 0.9
                ),
                EpisodeTranscriptAnalysisAPIChapter(
                    title: "The Sponsor Read",
                    startSegmentID: 1,
                    endSegmentID: 1,
                    startTime: 5,
                    endTime: 12,
                    confidence: 0.8
                )
            ],
            summary: summary ?? EpisodeTranscriptAnalysisAPISummary(
                summary: "A warm welcome followed by a sponsor read.",
                oneLineDescription: "A short test episode",
                claims: [
                    EpisodeTranscriptAnalysisAPIClaim(
                        text: "The host welcomes listeners back.",
                        evidenceSegmentID: 0
                    )
                ]
            ),
            warnings: [],
            usage: EpisodeTranscriptAnalysisAPIUsage(
                promptTokenCount: 100,
                candidatesTokenCount: 20,
                thoughtsTokenCount: 30,
                totalTokenCount: 150
            )
        )
    }
}

/// A service-job reader that answers polls from a script; every other use
/// of the analysis service is gone, so this is the only client a store
/// needs in tests.
final class ScriptedTranscriptAnalysisDrainClient: EpisodeTranscriptAnalysisClient, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<EpisodeTranscriptAnalysisJobPollOutcome, any Error>]
    private var polls: [String] = []

    init(_ outcomes: [Result<EpisodeTranscriptAnalysisJobPollOutcome, any Error>] = []) {
        self.outcomes = outcomes
    }

    var polledJobIDs: [String] {
        lock.withLock { polls }
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        let outcome: Result<EpisodeTranscriptAnalysisJobPollOutcome, any Error>? = lock.withLock {
            polls.append(id)
            return outcomes.isEmpty ? nil : outcomes.removeFirst()
        }
        guard let outcome else {
            throw CancellationError()
        }
        return try outcome.get()
    }
}
