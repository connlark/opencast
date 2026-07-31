import Foundation
import Observation
import OpenCastTranscription
import SwiftData

@Observable
final class EpisodeAdAnalysisStore {
    private(set) var records: [EpisodeAdAnalysisRecord] = []
    private(set) var lastErrorMessage: String?
    private var lastErrorEpisodeID: String?

    @ObservationIgnored private let client: any EpisodeAdAnalysisClient
    @ObservationIgnored private let fileStore: EpisodeAdAnalysisFileStore
    @ObservationIgnored private let analysisUnavailableMessage: String?
    @ObservationIgnored private let pollingTimeout: Duration
    @ObservationIgnored private let resumeTTL: TimeInterval
    @ObservationIgnored private let resumeInitialPollAfter: TimeInterval
    @ObservationIgnored private let pollingSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let preparationGate: @Sendable () async throws -> Void
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    private var activeEpisodeID: String?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private let stateChanges = StoreChangeNotifier()
    @ObservationIgnored var onEpisodeStateChanged: ((String) -> Void)?

    init(
        fileStore: EpisodeAdAnalysisFileStore = EpisodeAdAnalysisFileStore(),
        configuration: AdAnalysisBackendConfiguration = .current,
        transport: any EpisodeAdAnalysisHTTPTransport & AppAttestHTTPTransport = URLSession.shared,
        preparationGate: @escaping @Sendable () async throws -> Void = {}
    ) {
        client = URLSessionEpisodeAdAnalysisClient(
            configuration: configuration,
            transport: transport
        )
        self.fileStore = fileStore
        analysisUnavailableMessage = configuration.analysisUnavailableMessage
        pollingTimeout = .seconds(1_800)
        resumeTTL = 3_600
        resumeInitialPollAfter = 1
        pollingSleep = { duration in
            try await Task.sleep(for: duration)
        }
        self.preparationGate = preparationGate
    }

    init(
        client: any EpisodeAdAnalysisClient,
        fileStore: EpisodeAdAnalysisFileStore = EpisodeAdAnalysisFileStore(),
        analysisUnavailableMessage: String? = nil,
        pollingTimeout: Duration = .seconds(1_800),
        resumeTTL: TimeInterval = 3_600,
        resumeInitialPollAfter: TimeInterval = 1,
        pollingSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        preparationGate: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.client = client
        self.fileStore = fileStore
        self.analysisUnavailableMessage = analysisUnavailableMessage
        self.pollingTimeout = pollingTimeout
        self.resumeTTL = resumeTTL
        self.resumeInitialPollAfter = resumeInitialPollAfter
        self.pollingSleep = pollingSleep
        self.preparationGate = preparationGate
    }

    deinit {
        activeTask?.cancel()
    }

    var canStartAnalysis: Bool {
        analysisUnavailableMessage == nil
    }

    var analysisStartUnavailableMessage: String? {
        analysisUnavailableMessage
    }

    var hasActiveJob: Bool {
        activeTask != nil
    }

    func isRunning(for episodeID: String) -> Bool {
        activeEpisodeID == episodeID && activeTask != nil
    }

    var changeSequence: Int {
        stateChanges.sequence
    }

    func waitForChange(after sequence: Int) async throws {
        try await stateChanges.wait(after: sequence)
    }

    // Test seam — no production callers (dead-code audit Low 40).
    func cancelActiveJob() {
        activeTask?.cancel()
    }

    func load(modelContext: ModelContext) {
        do {
            let resumeContext = try reconcile(modelContext: modelContext)
            try reload(modelContext: modelContext)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
            if let resumeContext {
                startResumingAnalysis(resumeContext, modelContext: modelContext)
            }
        } catch {
            recordFailure(error)
        }
    }

    func record(for episodeID: String) -> EpisodeAdAnalysisRecord? {
        records.first { $0.episodeID == episodeID }
    }

    func lastErrorMessage(for episodeID: String) -> String? {
        guard lastErrorEpisodeID == episodeID else {
            return nil
        }
        return lastErrorMessage
    }

    func document(for episodeID: String) -> EpisodeAdAnalysisDocument? {
        guard let record = record(for: episodeID),
              let relativePath = record.analysisRelativePath
        else {
            return nil
        }
        return try? fileStore.read(relativePath: relativePath)
    }

    func loadDocument(for episodeID: String) async throws -> EpisodeAdAnalysisDocument {
        guard let record = record(for: episodeID),
              let relativePath = record.analysisRelativePath
        else {
            throw EpisodeAdAnalysisError.analysisDocumentMissing
        }
        return try await fileStore.readOffCaller(relativePath: relativePath)
    }

    func isCurrentAnalysisDocument(
        _ analysisDocument: EpisodeAdAnalysisDocument,
        for transcriptDocument: EpisodeTranscriptDocument
    ) -> Bool {
        let segments = normalizedSegments(for: transcriptDocument)
        let fingerprint = fileStore.transcriptFingerprint(
            for: transcriptDocument,
            segments: segments
        )
        return Self.isCurrentAnalysisDocument(
            analysisDocument,
            for: transcriptDocument,
            transcriptFingerprint: fingerprint,
            transcriptSegmentCount: segments.count
        )
    }

    /// Normalizing and fingerprinting a full transcript scales with episode
    /// length; this variant keeps that work off the caller's actor.
    @concurrent
    func isCurrentAnalysisDocumentOffCaller(
        _ analysisDocument: EpisodeAdAnalysisDocument,
        for transcriptDocument: EpisodeTranscriptDocument
    ) async -> Bool {
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(transcriptDocument.segments)
        let fingerprint = fileStore.transcriptFingerprint(
            for: transcriptDocument,
            segments: segments
        )
        return Self.isCurrentAnalysisDocument(
            analysisDocument,
            for: transcriptDocument,
            transcriptFingerprint: fingerprint,
            transcriptSegmentCount: segments.count
        )
    }

    func hasCurrentCompletedAnalysis(
        for transcriptDocument: EpisodeTranscriptDocument
    ) async -> Bool {
        guard let analysisRecord = record(for: transcriptDocument.episodeID),
              analysisRecord.state == .completed
        else {
            return false
        }

        let recordStamp = analysisRecord.updatedAt
        guard let analysisDocument = try? await loadDocument(
            for: transcriptDocument.episodeID
        ) else {
            return false
        }
        let isCurrent = await isCurrentAnalysisDocumentOffCaller(
            analysisDocument,
            for: transcriptDocument
        )
        return record(for: transcriptDocument.episodeID)?.updatedAt == recordStamp
            && isCurrent
    }

    func jobState(
        for document: EpisodeTranscriptDocument?,
        transcriptState: EpisodeTranscriptState? = .completed
    ) -> EpisodeAdAnalysisJobState {
        guard let document else {
            return .unavailable("Transcript unavailable.")
        }
        if isRunning(for: document.episodeID) {
            return .running
        }
        guard transcriptState == .completed else {
            return .unavailable(EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription)
        }
        let segments = normalizedSegments(for: document)
        guard !segments.isEmpty else {
            return .unavailable("Transcript has no segments.")
        }

        return jobState(for: document, segments: segments)
    }

    func episodeDetailState(
        for document: EpisodeTranscriptDocument?,
        transcriptState: EpisodeTranscriptState?,
        analysisDocument: EpisodeAdAnalysisDocument?
    ) -> (jobState: EpisodeAdAnalysisJobState, hasCurrentCompletedAnalysis: Bool) {
        guard let document else {
            return (.unavailable("Transcript unavailable."), false)
        }
        guard transcriptState == .completed else {
            return (
                .unavailable(EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription),
                false
            )
        }

        let segments = normalizedSegments(for: document)
        guard !segments.isEmpty else {
            return (.unavailable("Transcript has no segments."), false)
        }

        let fingerprint = fileStore.transcriptFingerprint(for: document, segments: segments)
        let state = jobState(
            for: document,
            segments: segments,
            transcriptFingerprint: fingerprint
        )
        let hasCurrentCompletedAnalysis = analysisDocument.map {
            Self.isCurrentAnalysisDocument(
                $0,
                for: document,
                transcriptFingerprint: fingerprint,
                transcriptSegmentCount: segments.count
            )
        } ?? false
        return (state, hasCurrentCompletedAnalysis)
    }

    private func jobState(
        for document: EpisodeTranscriptDocument,
        segments: [OpenCastTranscriptSegment],
        transcriptFingerprint: String? = nil
    ) -> EpisodeAdAnalysisJobState {
        if activeEpisodeID == document.episodeID && activeTask != nil {
            return .running
        }

        guard let record = record(for: document.episodeID) else {
            if activeTask != nil {
                return .running
            }
            if let analysisUnavailableMessage {
                return .unavailable(analysisUnavailableMessage)
            }
            return .ready
        }

        switch record.state {
        case .queued, .running:
            return .running
        case .completed:
            let fingerprint = transcriptFingerprint
                ?? fileStore.transcriptFingerprint(for: document, segments: segments)
            let isStale = !isUsableCurrentRecord(
                record,
                for: document,
                transcriptFingerprint: fingerprint,
                transcriptSegmentCount: segments.count
            )
            if isStale && activeTask != nil {
                return .running
            }
            return .completed(record, isStale: isStale)
        case .failed:
            if activeTask != nil {
                return .running
            }
            let fingerprint = transcriptFingerprint
                ?? fileStore.transcriptFingerprint(for: document, segments: segments)
            let isStale = !isUsableCurrentRecord(
                record,
                for: document,
                transcriptFingerprint: fingerprint,
                transcriptSegmentCount: segments.count
            )
            return .failed(record, isStale: isStale)
        }
    }

    func startAnalysis(
        transcript document: EpisodeTranscriptDocument,
        transcriptState: EpisodeTranscriptState? = .completed,
        modelContext: ModelContext
    ) {
        guard activeTask == nil else {
            recordFailure(EpisodeAdAnalysisError.anotherJobActive, episodeID: document.episodeID)
            return
        }
        if let analysisUnavailableMessage {
            recordFailureMessage(analysisUnavailableMessage, episodeID: document.episodeID)
            return
        }
        guard transcriptState == .completed else {
            recordFailure(EpisodeAdAnalysisError.transcriptNotCompleted, episodeID: document.episodeID)
            return
        }

        clearFailure(episodeID: document.episodeID)
        let runID = UUID()
        activeEpisodeID = document.episodeID
        activeRunID = runID
        activeTask = Task {
            await runAnalysis(
                runID: runID,
                transcript: document,
                modelContext: modelContext
            )
        }
        stateChanges.notify()
        notifyEpisodeStateChanged(document.episodeID)
        SoundLabResponsivenessDiagnostics.mark(
            "analysis-store-reports-running",
            episodeID: document.episodeID
        )
    }

    /// Durable import of a server-produced completed analysis (cloud detect
    /// pass): writes the document and upserts a completed record through the
    /// same path a device analysis uses. Mirror of
    /// `EpisodeTranscriptionStore.importRemoteTranscript`.
    func importCompletedAnalysis(
        _ document: EpisodeAdAnalysisDocument,
        modelContext: ModelContext
    ) throws {
        let relativePath = fileStore.relativePath(
            episodeID: document.episodeID,
            transcriptFingerprint: document.transcriptFingerprint
        )
        try fileStore.write(document, relativePath: relativePath)
        try upsertRecord(
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            transcriptFingerprint: document.transcriptFingerprint,
            transcriptUpdatedAt: document.transcriptUpdatedAt,
            transcriptSegmentCount: document.transcriptSegmentCount,
            transcriptState: document.transcriptState,
            state: .completed,
            analysisRelativePath: relativePath,
            model: document.model,
            policy: document.policy,
            spanCount: document.spans.count,
            warningCount: document.warnings.count,
            errorMessage: nil,
            modelContext: modelContext
        )
        try commit(episodeID: document.episodeID, modelContext: modelContext, resort: true)
        clearFailure(episodeID: document.episodeID)
    }

    func deleteAnalysis(episodeID: String, modelContext: ModelContext) {
        if activeEpisodeID == episodeID {
            activeTask?.cancel()
        }

        do {
            let matchingRecords = try fetchRecords(episodeID: episodeID, modelContext: modelContext)
            for record in matchingRecords {
                try fileStore.delete(relativePath: record.analysisRelativePath)
                modelContext.delete(record)
            }
            try fileStore.deleteAnalyses(forEpisodeID: episodeID)
            try modelContext.save()
            try reload(modelContext: modelContext)
            clearFailure(episodeID: episodeID)
            notifyEpisodeStateChanged(episodeID)
        } catch {
            recordFailure(error, episodeID: episodeID)
        }
    }

    func deleteAnalyses(forPodcastID podcastID: String, modelContext: ModelContext) throws {
        let records = try fetchRecords(forPodcastID: podcastID, modelContext: modelContext)
        for record in records {
            if activeEpisodeID == record.episodeID {
                activeTask?.cancel()
            }
            try fileStore.delete(relativePath: record.analysisRelativePath)
            try fileStore.deleteAnalyses(forEpisodeID: record.episodeID)
            modelContext.delete(record)
        }
        if !records.isEmpty {
            try modelContext.save()
        }
        try reload(modelContext: modelContext)
        clearFailure()
        for record in records {
            notifyEpisodeStateChanged(record.episodeID)
        }
    }

    func nukeAllAnalyses(modelContext: ModelContext) async throws {
        await cancelActiveJobAndWait()
        for record in try fetchRecords(modelContext: modelContext) {
            modelContext.delete(record)
        }
        try fileStore.deleteAllAnalyses()
        try modelContext.save()
        records.removeAll()
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
        stateChanges.notify()
    }

    private func cancelActiveJobAndWait() async {
        guard let activeTask else {
            return
        }
        activeTask.cancel()
        await activeTask.value
    }

    private func runAnalysis(
        runID: UUID,
        transcript document: EpisodeTranscriptDocument,
        modelContext: ModelContext
    ) async {
        defer {
            if ownsActiveRun(episodeID: document.episodeID, runID: runID) {
                activeTask = nil
                activeEpisodeID = nil
                activeRunID = nil
                stateChanges.notify()
            }
        }

        guard !Task.isCancelled else {
            return
        }

        var relativePath: String?
        do {
            let preparation = try await prepareAnalysis(transcript: document)
            relativePath = preparation.relativePath
            try Task.checkCancellation()
            guard ownsActiveRun(episodeID: document.episodeID, runID: runID) else {
                throw CancellationError()
            }

            try upsertRecord(
                episodeID: document.episodeID,
                podcastID: document.podcastID,
                transcriptFingerprint: preparation.fingerprint,
                transcriptUpdatedAt: document.updatedAt,
                transcriptSegmentCount: preparation.segments.count,
                transcriptState: .completed,
                state: .running,
                analysisRelativePath: preparation.relativePath,
                model: "",
                policy: "",
                spanCount: 0,
                warningCount: 0,
                errorMessage: nil,
                modelContext: modelContext
            )
            try commit(episodeID: document.episodeID, modelContext: modelContext, resort: true)

            let submitOutcome: EpisodeAdAnalysisSubmitOutcome
            do {
                submitOutcome = try await client.analyze(preparation.request)
            } catch is URLError {
                // A lost submit response is recovered through the poll loop:
                // the job ID is the transcript fingerprint, so it is known
                // without the response. If the submit landed, polling attaches
                // to the running job (or re-reads the completed result, which
                // the worker serves idempotently until its TTL purge); if it
                // never landed, the poll's job_not_found resubmit path starts
                // it fresh.
                submitOutcome = .accepted(jobID: preparation.fingerprint, pollAfter: 1)
            }
            let response: EpisodeAdAnalysisAPIResponse
            switch submitOutcome {
            case .completed(let completedResponse):
                response = completedResponse
            case .accepted(let jobID, let pollAfter):
                guard jobID == preparation.fingerprint else {
                    throw Self.jobIDMismatchError()
                }
                try persistAcceptedJob(
                    episodeID: document.episodeID,
                    fingerprint: preparation.fingerprint,
                    modelContext: modelContext
                )
                response = try await pollUntilCompleted(
                    jobID: jobID,
                    initialPollAfter: pollAfter,
                    resubmit: { [client] in
                        try await client.analyze(preparation.request)
                    }
                )
            }
            try Task.checkCancellation()
            guard ownsActiveRun(episodeID: document.episodeID, runID: runID) else {
                throw CancellationError()
            }

            let analysisDocument = makeDocument(
                transcript: document,
                response: response,
                fingerprint: preparation.fingerprint,
                transcriptSegmentCount: preparation.segments.count
            )
            try completeAnalysis(
                episodeID: document.episodeID,
                fingerprint: preparation.fingerprint,
                relativePath: preparation.relativePath,
                document: analysisDocument,
                response: response,
                modelContext: modelContext
            )
            clearFailure(episodeID: document.episodeID)
        } catch is CancellationError {
            return
        } catch {
            markFailed(
                episodeID: document.episodeID,
                relativePath: relativePath,
                error: error,
                modelContext: modelContext
            )
        }
    }

    @concurrent
    private func prepareAnalysis(
        transcript document: EpisodeTranscriptDocument
    ) async throws -> EpisodeAdAnalysisPreparation {
        try await preparationGate()
        try Task.checkCancellation()
        SoundLabResponsivenessDiagnostics.mark(
            "analysis-normalize-fingerprint-begin",
            episodeID: document.episodeID
        )

        let segments = OpenCastTranscriptSegmentNormalizer.normalized(document.segments)
        guard !segments.isEmpty else {
            throw EpisodeAdAnalysisError.transcriptNotCompleted
        }
        let fingerprint = fileStore.transcriptFingerprint(
            for: document,
            segments: segments
        )
        let relativePath = fileStore.relativePath(
            episodeID: document.episodeID,
            transcriptFingerprint: fingerprint
        )
        let request = Self.makeRequest(
            transcript: document,
            segments: segments,
            fingerprint: fingerprint,
            requestID: UUID().uuidString
        )
        SoundLabResponsivenessDiagnostics.mark(
            "analysis-normalize-fingerprint-end",
            episodeID: document.episodeID
        )
        try Task.checkCancellation()

        return EpisodeAdAnalysisPreparation(
            segments: segments,
            fingerprint: fingerprint,
            relativePath: relativePath,
            request: request
        )
    }

    private func startResumingAnalysis(
        _ context: EpisodeAdAnalysisResumeContext,
        modelContext: ModelContext
    ) {
        guard activeTask == nil else {
            return
        }

        let runID = UUID()
        activeEpisodeID = context.episodeID
        activeRunID = runID
        activeTask = Task {
            await runResumedAnalysis(
                runID: runID,
                context: context,
                modelContext: modelContext
            )
        }
    }

    private func runResumedAnalysis(
        runID: UUID,
        context: EpisodeAdAnalysisResumeContext,
        modelContext: ModelContext
    ) async {
        defer {
            if ownsActiveRun(episodeID: context.episodeID, runID: runID) {
                activeTask = nil
                activeEpisodeID = nil
                activeRunID = nil
                stateChanges.notify()
            }
        }

        do {
            let response = try await pollUntilCompleted(
                jobID: context.transcriptFingerprint,
                initialPollAfter: resumeInitialPollAfter,
                resubmit: nil
            )
            try Task.checkCancellation()
            guard ownsActiveRun(episodeID: context.episodeID, runID: runID) else {
                throw CancellationError()
            }

            let document = makeDocument(
                episodeID: context.episodeID,
                podcastID: context.podcastID,
                transcriptUpdatedAt: context.transcriptUpdatedAt,
                response: response,
                fingerprint: context.transcriptFingerprint,
                transcriptSegmentCount: context.transcriptSegmentCount
            )
            try completeAnalysis(
                episodeID: context.episodeID,
                fingerprint: context.transcriptFingerprint,
                relativePath: context.analysisRelativePath,
                document: document,
                response: response,
                modelContext: modelContext
            )
            clearFailure(episodeID: context.episodeID)
        } catch is CancellationError {
            return
        } catch {
            markFailed(
                episodeID: context.episodeID,
                relativePath: context.analysisRelativePath,
                error: error,
                modelContext: modelContext
            )
        }
    }

    private func persistAcceptedJob(
        episodeID: String,
        fingerprint: String,
        modelContext: ModelContext
    ) throws {
        guard let record = try fetchStoredRecord(
            episodeID: episodeID,
            modelContext: modelContext
        ), record.state == .running,
           record.transcriptFingerprint == fingerprint
        else {
            throw CancellationError()
        }

        record.jobAcceptedAt = .now
        record.updatedAt = .now
        try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
    }

    private func pollUntilCompleted(
        jobID: String,
        initialPollAfter: TimeInterval,
        resubmit: (@Sendable () async throws -> EpisodeAdAnalysisSubmitOutcome)?
    ) async throws -> EpisodeAdAnalysisAPIResponse {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: pollingTimeout)
        var activeJobID = jobID
        var pollAfter = Self.clampedPollAfter(initialPollAfter)
        var didResubmit = false
        var consecutiveURLErrors = 0

        while true {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else {
                throw EpisodeAdAnalysisError.analysisTimedOut
            }

            let remaining = now.duration(to: deadline)
            let delay = min(Duration.seconds(pollAfter), remaining)
            if delay > .zero {
                try await pollingSleep(delay)
            }
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw EpisodeAdAnalysisError.analysisTimedOut
            }

            do {
                switch try await client.pollJob(id: activeJobID) {
                case .running(let nextPollAfter):
                    consecutiveURLErrors = 0
                    pollAfter = Self.clampedPollAfter(nextPollAfter)
                case .completed(let response):
                    return response
                }
            } catch let error as URLError {
                consecutiveURLErrors += 1
                guard consecutiveURLErrors <= 3 else {
                    throw error
                }
            } catch let error as EpisodeAdAnalysisHTTPError
                where error.isTransientJobFailure && !didResubmit && resubmit != nil
            {
                didResubmit = true
                consecutiveURLErrors = 0
                guard let resubmit else {
                    throw error
                }
                switch try await resubmit() {
                case .completed(let response):
                    return response
                case .accepted(let resubmittedJobID, let nextPollAfter):
                    guard resubmittedJobID == jobID else {
                        throw Self.jobIDMismatchError()
                    }
                    activeJobID = resubmittedJobID
                    pollAfter = Self.clampedPollAfter(nextPollAfter)
                }
            }
        }
    }

    private func completeAnalysis(
        episodeID: String,
        fingerprint: String,
        relativePath: String,
        document: EpisodeAdAnalysisDocument,
        response: EpisodeAdAnalysisAPIResponse,
        modelContext: ModelContext
    ) throws {
        guard let record = try fetchStoredRecord(
            episodeID: episodeID,
            modelContext: modelContext
        ), record.state == .running,
           record.transcriptFingerprint == fingerprint
        else {
            throw CancellationError()
        }

        // Same philosophy as EpisodeRemoteAdAnalysisMapper: a span kind this
        // build doesn't recognize means the response cannot be trusted to
        // skip audio. Fail cleanly so callers fall back to a fresh analysis.
        guard !response.spans.contains(where: { $0.kind == .unknown }) else {
            throw EpisodeAdAnalysisError.unrecognizedSpanKind
        }

        try fileStore.write(document, relativePath: relativePath)
        record.state = .completed
        record.analysisRelativePath = relativePath
        record.model = response.model
        record.policy = response.policy
        record.spanCount = response.spans.count
        record.warningCount = response.warnings.count
        record.errorMessage = nil
        record.failureKind = nil
        record.jobAcceptedAt = nil
        record.updatedAt = .now
        try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
    }

    private static func clampedPollAfter(_ value: TimeInterval) -> TimeInterval {
        min(max(value, 0), 120)
    }

    private static func jobIDMismatchError() -> EpisodeAdAnalysisHTTPError {
        EpisodeAdAnalysisHTTPError(statusCode: -1, code: "job_id_mismatch", detail: nil)
    }

    private nonisolated static func makeRequest(
        transcript document: EpisodeTranscriptDocument,
        segments: [OpenCastTranscriptSegment],
        fingerprint: String,
        requestID: String
    ) -> EpisodeAdAnalysisAPIRequest {
        EpisodeAdAnalysisAPIRequest(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            requestID: requestID,
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            episodeTitle: nil,
            podcastTitle: nil,
            asyncSupported: true,
            transcript: EpisodeAdAnalysisAPITranscriptMetadata(
                languageCode: document.languageCode,
                audioDuration: document.audioDuration,
                modelIdentifier: document.modelIdentifier,
                modelVersion: document.modelVersion,
                modelTreeSHA256: document.modelTreeSHA256,
                fingerprint: fingerprint,
                updatedAt: document.updatedAt,
                state: EpisodeAdAnalysisContract.completedTranscriptState,
                segmentCount: segments.count
            ),
            segments: segments.map { segment in
                EpisodeAdAnalysisAPISegment(
                    id: segment.id,
                    start: segment.start,
                    end: segment.end,
                    text: segment.text
                )
            }
        )
    }

    private func makeDocument(
        transcript document: EpisodeTranscriptDocument,
        response: EpisodeAdAnalysisAPIResponse,
        fingerprint: String,
        transcriptSegmentCount: Int
    ) -> EpisodeAdAnalysisDocument {
        makeDocument(
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            transcriptUpdatedAt: document.updatedAt,
            response: response,
            fingerprint: fingerprint,
            transcriptSegmentCount: transcriptSegmentCount
        )
    }

    private func makeDocument(
        episodeID: String,
        podcastID: String,
        transcriptUpdatedAt: Date,
        response: EpisodeAdAnalysisAPIResponse,
        fingerprint: String,
        transcriptSegmentCount: Int
    ) -> EpisodeAdAnalysisDocument {
        EpisodeAdAnalysisDocument(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            episodeID: episodeID,
            podcastID: podcastID,
            requestID: response.requestID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcriptUpdatedAt,
            transcriptSegmentCount: transcriptSegmentCount,
            transcriptState: .completed,
            model: response.model,
            policy: response.policy,
            spans: response.spans.enumerated().map { index, span in
                EpisodeAdAnalysisSpan(
                    id: index,
                    kind: span.kind,
                    label: span.label,
                    startSegmentID: span.startSegmentID,
                    endSegmentID: span.endSegmentID,
                    startTime: span.startTime,
                    endTime: span.endTime,
                    confidence: span.confidence,
                    evidenceQuote: span.evidenceQuote
                )
            },
            warnings: response.warnings,
            usage: response.usage.map { usage in
                EpisodeAdAnalysisUsage(
                    promptTokenCount: usage.promptTokenCount,
                    candidatesTokenCount: usage.candidatesTokenCount,
                    totalTokenCount: usage.totalTokenCount
                )
            },
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func isUsableCurrentRecord(
        _ record: EpisodeAdAnalysisRecord,
        for document: EpisodeTranscriptDocument,
        transcriptFingerprint: String,
        transcriptSegmentCount: Int
    ) -> Bool {
        // A completed record from a pre-`promo_ad_breaks_v2` policy is
        // outdated even when its transcript still matches: the old contract's
        // cue-fragment spans must never render or skip again.
        // Whole-second comparison: the transcript's `updatedAt` loses its
        // fractional seconds on the `.iso8601` disk round trip, while the
        // SwiftData record keeps full precision, so exact equality would
        // brand a record seeded from an in-memory document permanently stale.
        return (record.state != .completed || record.policy == EpisodeAdAnalysisContract.expectedPolicy)
            && record.transcriptFingerprint == transcriptFingerprint
            && record.transcriptUpdatedAt.truncatedToWholeSeconds == document.updatedAt.truncatedToWholeSeconds
            && record.transcriptSegmentCount == transcriptSegmentCount
            && record.transcriptState == .completed
            && fileStore.documentExists(relativePath: record.analysisRelativePath)
    }

    private nonisolated static func isCurrentAnalysisDocument(
        _ analysisDocument: EpisodeAdAnalysisDocument,
        for transcriptDocument: EpisodeTranscriptDocument,
        transcriptFingerprint: String,
        transcriptSegmentCount: Int
    ) -> Bool {
        analysisDocument.policy == EpisodeAdAnalysisContract.expectedPolicy
            && analysisDocument.transcriptFingerprint == transcriptFingerprint
            && analysisDocument.transcriptUpdatedAt.truncatedToWholeSeconds
                == transcriptDocument.updatedAt.truncatedToWholeSeconds
            && analysisDocument.transcriptSegmentCount == transcriptSegmentCount
            && analysisDocument.transcriptState == .completed
    }

    private func normalizedSegments(for document: EpisodeTranscriptDocument) -> [OpenCastTranscriptSegment] {
        OpenCastTranscriptSegmentNormalizer.normalized(document.segments)
    }

    @discardableResult
    private func upsertRecord(
        episodeID: String,
        podcastID: String,
        transcriptFingerprint: String,
        transcriptUpdatedAt: Date,
        transcriptSegmentCount: Int,
        transcriptState: EpisodeTranscriptState,
        state: EpisodeAdAnalysisState,
        analysisRelativePath: String?,
        model: String,
        policy: String,
        spanCount: Int,
        warningCount: Int,
        errorMessage: String?,
        modelContext: ModelContext
    ) throws -> EpisodeAdAnalysisRecord {
        let matchingRecords = try fetchRecords(episodeID: episodeID, modelContext: modelContext)
        let record: EpisodeAdAnalysisRecord
        if let existingRecord = matchingRecords.first {
            record = existingRecord
        } else {
            record = EpisodeAdAnalysisRecord(
                episodeID: episodeID,
                podcastID: podcastID
            )
            modelContext.insert(record)
        }

        for duplicateRecord in matchingRecords.dropFirst() {
            try fileStore.delete(relativePath: duplicateRecord.analysisRelativePath)
            modelContext.delete(duplicateRecord)
        }

        record.podcastID = podcastID
        record.transcriptFingerprint = transcriptFingerprint
        record.transcriptUpdatedAt = transcriptUpdatedAt
        record.transcriptSegmentCount = transcriptSegmentCount
        record.transcriptState = transcriptState
        record.state = state
        record.analysisRelativePath = analysisRelativePath
        record.model = model
        record.policy = policy
        record.spanCount = spanCount
        record.warningCount = warningCount
        record.errorMessage = errorMessage
        record.failureKind = nil
        record.jobAcceptedAt = nil
        record.updatedAt = .now
        return record
    }

    private func markFailed(
        episodeID: String,
        relativePath: String?,
        error: Error,
        modelContext: ModelContext
    ) {
        do {
            guard let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) else {
                recordFailure(error, episodeID: episodeID)
                return
            }
            record.state = .failed
            record.errorMessage = error.localizedDescription
            record.failureKind = Self.failureKind(for: error)
            record.jobAcceptedAt = nil
            record.analysisRelativePath = relativePath ?? record.analysisRelativePath
            record.updatedAt = .now
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
            recordFailure(error, episodeID: episodeID)
        } catch {
            recordFailure(error, episodeID: episodeID)
        }
    }

    private static func failureKind(for error: Error) -> EpisodeAdAnalysisFailureKind {
        (error as? EpisodeAdAnalysisHTTPError)?.isCapExceeded == true ? .capExceeded : .generic
    }

    private func reconcile(modelContext: ModelContext) throws -> EpisodeAdAnalysisResumeContext? {
        let fetchedRecords = try fetchRecords(modelContext: modelContext)
        let now = Date.now
        var changed = false
        var resumeContext: EpisodeAdAnalysisResumeContext?
        for record in fetchedRecords {
            switch record.state {
            case .running:
                if resumeContext == nil,
                   let jobAcceptedAt = record.jobAcceptedAt,
                   now.timeIntervalSince(jobAcceptedAt) <= resumeTTL,
                   let context = EpisodeAdAnalysisResumeContext(record: record)
                {
                    resumeContext = context
                    continue
                }
                record.state = .failed
                record.errorMessage = "Promo/ad analysis was interrupted."
                record.failureKind = .generic
                record.jobAcceptedAt = nil
                record.updatedAt = now
                changed = true
            case .queued:
                record.state = .failed
                record.errorMessage = "Promo/ad analysis was interrupted."
                record.failureKind = .generic
                record.jobAcceptedAt = nil
                record.updatedAt = now
                changed = true
            case .completed:
                guard fileStore.documentExists(relativePath: record.analysisRelativePath) else {
                    record.state = .failed
                    record.errorMessage = "Promo/ad analysis document is missing."
                    record.failureKind = .generic
                    record.jobAcceptedAt = nil
                    record.updatedAt = now
                    changed = true
                    continue
                }
                if record.jobAcceptedAt != nil {
                    record.jobAcceptedAt = nil
                    changed = true
                }
            case .failed:
                if record.jobAcceptedAt != nil {
                    record.jobAcceptedAt = nil
                    changed = true
                }
            }
        }

        if changed {
            try modelContext.save()
        }
        return resumeContext
    }

    private func commit(
        episodeID: String,
        modelContext: ModelContext,
        resort: Bool = false
    ) throws {
        try modelContext.save()
        if let record = try fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) {
            updateLoadedRecord(record, resort: resort)
        } else {
            records.removeAll { $0.episodeID == episodeID }
            notifyEpisodeStateChanged(episodeID)
        }
    }

    private func updateLoadedRecord(_ record: EpisodeAdAnalysisRecord, resort: Bool = false) {
        if let index = records.firstIndex(where: { $0.episodeID == record.episodeID }) {
            records[index] = record
        } else {
            records.append(record)
        }

        if resort {
            records.sort { $0.updatedAt > $1.updatedAt }
        }
        notifyEpisodeStateChanged(record.episodeID)
    }

    private func reload(modelContext: ModelContext) throws {
        records = try fetchRecords(modelContext: modelContext)
    }

    private func fetchStoredRecord(
        episodeID: String,
        modelContext: ModelContext
    ) throws -> EpisodeAdAnalysisRecord? {
        let targetEpisodeID = episodeID
        var descriptor = FetchDescriptor<EpisodeAdAnalysisRecord>(
            predicate: #Predicate { record in
                record.episodeID == targetEpisodeID
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRecords(
        episodeID: String,
        modelContext: ModelContext
    ) throws -> [EpisodeAdAnalysisRecord] {
        let targetEpisodeID = episodeID
        return try modelContext.fetch(
            FetchDescriptor<EpisodeAdAnalysisRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetEpisodeID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func fetchRecords(
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) throws -> [EpisodeAdAnalysisRecord] {
        let targetPodcastID = podcastID
        return try modelContext.fetch(
            FetchDescriptor<EpisodeAdAnalysisRecord>(
                predicate: #Predicate { record in
                    record.podcastID == targetPodcastID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func fetchRecords(modelContext: ModelContext) throws -> [EpisodeAdAnalysisRecord] {
        try modelContext.fetch(
            FetchDescriptor<EpisodeAdAnalysisRecord>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        )
    }

    private func recordFailure(_ error: Error, episodeID: String? = nil) {
        lastErrorMessage = error.localizedDescription
        lastErrorEpisodeID = episodeID
        stateChanges.notify()
    }

    private func recordFailureMessage(_ message: String, episodeID: String? = nil) {
        lastErrorMessage = message
        lastErrorEpisodeID = episodeID
        stateChanges.notify()
    }

    private func clearFailure(episodeID: String? = nil) {
        guard episodeID == nil || lastErrorEpisodeID == nil || lastErrorEpisodeID == episodeID else {
            return
        }
        let hadFailure = lastErrorMessage != nil || lastErrorEpisodeID != nil
        lastErrorMessage = nil
        lastErrorEpisodeID = nil
        if hadFailure {
            stateChanges.notify()
        }
    }

    private func notifyEpisodeStateChanged(_ episodeID: String) {
        stateChanges.notify()
        onEpisodeStateChanged?(episodeID)
    }

    private func ownsActiveRun(episodeID: String, runID: UUID) -> Bool {
        activeEpisodeID == episodeID && activeRunID == runID
    }
}
