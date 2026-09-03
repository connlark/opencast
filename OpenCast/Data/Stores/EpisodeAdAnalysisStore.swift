import Foundation
import Observation
import OpenCastTranscription
import SwiftData

@Observable
final class EpisodeAdAnalysisStore {
    @ObservationIgnored private let recordSet = AnalysisRecordSet<EpisodeAdAnalysisRecord>(descriptors: EpisodeAdAnalysisStore.fetchDescriptors)
    /// Episode-ID groups that held more than one record and were collapsed to
    /// a proven survivor, cumulative for this process (startup repair plus
    /// migration collisions). Diagnostics-only; never names episodes.
    private(set) var duplicateRepairCount = 0

    @ObservationIgnored private let client: any EpisodeAdAnalysisClient
    @ObservationIgnored private let fileStore: EpisodeAdAnalysisFileStore
    @ObservationIgnored private let analysisUnavailableMessage: String?
    @ObservationIgnored private let poller: AnalysisJobPoller<EpisodeAdAnalysisAPIResponse>
    @ObservationIgnored private let resumeTTL: TimeInterval
    @ObservationIgnored private let resumeInitialPollAfter: TimeInterval
    @ObservationIgnored private let preparationGate: @Sendable () async throws -> Void
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    private var activeEpisodeID: String?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private let failures = AnalysisFailureSurface()
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
        poller = Self.makePoller(timeout: .seconds(1_800)) { duration in
            try await Task.sleep(for: duration)
        }
        resumeTTL = 3_600
        resumeInitialPollAfter = 1
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
        poller = Self.makePoller(timeout: pollingTimeout, sleep: pollingSleep)
        self.resumeTTL = resumeTTL
        self.resumeInitialPollAfter = resumeInitialPollAfter
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

    var lastErrorMessage: String? {
        failures.lastErrorMessage
    }

    var changeSequence: Int {
        failures.changeSequence
    }

    func waitForChange(after sequence: Int) async throws {
        try await failures.waitForChange(after: sequence)
    }

    // Test seam — no production callers (dead-code audit Low 40).
    func cancelActiveJob() {
        activeTask?.cancel()
    }

    func load(modelContext: ModelContext) {
        do {
            let resumeContext = try reconcile(modelContext: modelContext)
            try recordSet.reload(modelContext: modelContext)
            failures.reset()
            if let resumeContext {
                startResumingAnalysis(resumeContext, modelContext: modelContext)
            }
        } catch {
            failures.record(error)
        }
    }

    var records: [EpisodeAdAnalysisRecord] {
        recordSet.records
    }

    func record(for episodeID: String) -> EpisodeAdAnalysisRecord? {
        recordSet.record(for: episodeID)
    }

    func lastErrorMessage(for episodeID: String) -> String? {
        failures.message(for: episodeID)
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

    /// Resolved by the store so the diagnostics sheet never duplicates the
    /// Application Support layout rules.
    func diagnosticsDocumentFileURL(for episodeID: String) -> URL? {
        record(for: episodeID)?.analysisRelativePath.map(fileStore.fileURL(relativePath:))
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
    ) async -> (jobState: EpisodeAdAnalysisJobState, hasCurrentCompletedAnalysis: Bool) {
        guard let document else {
            return (.unavailable("Transcript unavailable."), false)
        }
        guard transcriptState == .completed else {
            return (
                .unavailable(EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription),
                false
            )
        }

        // Normalize + fingerprint scale with episode length and the detail
        // surface calls this per content load; run them off the main actor,
        // hopping back only for the record lookups.
        let (segments, fingerprint) = await normalizedFingerprintOffCaller(for: document)
        guard !segments.isEmpty else {
            return (.unavailable("Transcript has no segments."), false)
        }

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

    @concurrent
    private func normalizedFingerprintOffCaller(
        for document: EpisodeTranscriptDocument
    ) async -> (segments: [OpenCastTranscriptSegment], fingerprint: String) {
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(document.segments)
        return (segments, fileStore.transcriptFingerprint(for: document, segments: segments))
    }

    private func jobState(
        for document: EpisodeTranscriptDocument,
        segments: [OpenCastTranscriptSegment],
        transcriptFingerprint: String? = nil
    ) -> EpisodeAdAnalysisJobState {
        // Running is reported only for the episode the active task belongs
        // to. A store-global "any job active" signal here would mark every
        // other episode's detail and transcript surfaces as detecting ads,
        // and would mask a real failed record for as long as the unrelated
        // job runs.
        if activeEpisodeID == document.episodeID && activeTask != nil {
            return .running
        }

        guard let record = record(for: document.episodeID) else {
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
            return .completed(record, isStale: isStale)
        case .failed:
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
            failures.record(EpisodeAdAnalysisError.anotherJobActive, episodeID: document.episodeID)
            return
        }
        if let analysisUnavailableMessage {
            failures.record(message: analysisUnavailableMessage, episodeID: document.episodeID)
            return
        }
        guard transcriptState == .completed else {
            failures.record(EpisodeAdAnalysisError.transcriptNotCompleted, episodeID: document.episodeID)
            return
        }

        failures.clear(episodeID: document.episodeID)
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
        failures.stateChanges.notify()
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
        failures.clear(episodeID: document.episodeID)
    }

    func deleteAnalysis(episodeID: String, modelContext: ModelContext) {
        if activeEpisodeID == episodeID {
            activeTask?.cancel()
        }

        do {
            let matchingRecords = try recordSet.fetchRecords(episodeID: episodeID, modelContext: modelContext)
            for record in matchingRecords {
                try fileStore.delete(relativePath: record.analysisRelativePath)
                modelContext.delete(record)
            }
            try fileStore.deleteAnalyses(forEpisodeID: episodeID)
            try modelContext.save()
            try recordSet.reload(modelContext: modelContext)
            failures.clear(episodeID: episodeID)
            notifyEpisodeStateChanged(episodeID)
        } catch {
            failures.record(error, episodeID: episodeID)
        }
    }

    func deleteAnalyses(forPodcastID podcastID: String, modelContext: ModelContext) throws {
        let records = try recordSet.fetchRecords(forPodcastID: podcastID, modelContext: modelContext)
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
        try recordSet.reload(modelContext: modelContext)
        failures.clear()
        for record in records {
            notifyEpisodeStateChanged(record.episodeID)
        }
    }

    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws {
        let migratingRecords = try recordSet.fetchRecords(episodeID: oldEpisodeID, modelContext: modelContext)
        guard !migratingRecords.isEmpty else {
            return
        }

        let targetRecords = try recordSet.fetchRecords(episodeID: newEpisodeID, modelContext: modelContext)
        try fileStore.migrateAnalyses(fromEpisodeID: oldEpisodeID, to: newEpisodeID)
        let newDirectory = "\(EpisodeAdAnalysisFileStore.directoryName)/\(fileStore.safeStem(newEpisodeID))"
        for record in migratingRecords {
            record.episodeID = newEpisodeID
            record.podcastID = canonicalPodcastID
            if let relativePath = record.analysisRelativePath,
               let fileName = relativePath.split(separator: "/").last {
                record.analysisRelativePath = "\(newDirectory)/\(fileName)"
            }
        }

        if !targetRecords.isEmpty {
            duplicateRepairCount += 1
            _ = reconciler.collapseDuplicateRecords(
                migratingRecords + targetRecords,
                subscribedFeedURLs: EpisodeSidecarRepair.subscribedFeedURLs(modelContext: modelContext),
                modelContext: modelContext
            )
        }

        // Records were re-keyed in place, but the keyed index only rebuilds
        // on a `records` reassignment. Reload — like the transcription twin —
        // so lookups observe the successor identity.
        try recordSet.reload(modelContext: modelContext)
        notifyEpisodeStateChanged(newEpisodeID)
    }

    func nukeAllAnalyses(modelContext: ModelContext) async throws {
        await cancelActiveJobAndWait()
        for record in try recordSet.fetchRecords(modelContext: modelContext) {
            modelContext.delete(record)
        }
        try fileStore.deleteAllAnalyses()
        try modelContext.save()
        recordSet.removeAll()
        failures.reset()
        failures.stateChanges.notify()
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
                failures.stateChanges.notify()
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
            failures.clear(episodeID: document.episodeID)
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
        _ context: AnalysisResumeContext,
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
        context: AnalysisResumeContext,
        modelContext: ModelContext
    ) async {
        defer {
            if ownsActiveRun(episodeID: context.episodeID, runID: runID) {
                activeTask = nil
                activeEpisodeID = nil
                activeRunID = nil
                failures.stateChanges.notify()
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
            failures.clear(episodeID: context.episodeID)
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
        guard let record = try recordSet.fetchStoredRecord(
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
        try await poller.pollUntilCompleted(
            jobID: jobID,
            initialPollAfter: initialPollAfter,
            poll: { [client] jobID in
                try await client.pollJob(id: jobID)
            },
            resubmit: resubmit
        )
    }

    private static func makePoller(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) -> AnalysisJobPoller<EpisodeAdAnalysisAPIResponse> {
        AnalysisJobPoller(
            timeout: timeout,
            sleep: sleep,
            isTransientJobFailure: { ($0 as? EpisodeAdAnalysisHTTPError)?.isTransientJobFailure == true },
            timedOutError: EpisodeAdAnalysisError.analysisTimedOut,
            jobIDMismatchError: jobIDMismatchError()
        )
    }

    private func completeAnalysis(
        episodeID: String,
        fingerprint: String,
        relativePath: String,
        document: EpisodeAdAnalysisDocument,
        response: EpisodeAdAnalysisAPIResponse,
        modelContext: ModelContext
    ) throws {
        guard let record = try recordSet.fetchStoredRecord(
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
        state: EpisodeAnalysisRecordState,
        analysisRelativePath: String?,
        model: String,
        policy: String,
        spanCount: Int,
        warningCount: Int,
        errorMessage: String?,
        modelContext: ModelContext
    ) throws -> EpisodeAdAnalysisRecord {
        let matchingRecords = try recordSet.fetchRecords(episodeID: episodeID, modelContext: modelContext)
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
            guard let record = try recordSet.fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) else {
                failures.record(error, episodeID: episodeID)
                return
            }
            record.state = .failed
            record.errorMessage = error.localizedDescription
            record.failureKind = Self.failureKind(for: error)
            record.jobAcceptedAt = nil
            record.analysisRelativePath = relativePath ?? record.analysisRelativePath
            record.updatedAt = .now
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
            failures.record(error, episodeID: episodeID)
        } catch {
            failures.record(error, episodeID: episodeID)
        }
    }

    private static func failureKind(for error: Error) -> EpisodeAnalysisFailureKind {
        (error as? EpisodeAdAnalysisHTTPError)?.isCapExceeded == true ? .capExceeded : .generic
    }

    private static let reconcileMessages = AnalysisRecordReconcileMessages(
        interrupted: "Promo/ad analysis was interrupted.",
        documentMissing: "Promo/ad analysis document is missing.",
        transcriptMismatch: "Promo/ad analysis no longer matches the transcript."
    )

    private var reconciler: AnalysisRecordReconciler<EpisodeAdAnalysisRecord> {
        AnalysisRecordReconciler(
            fileStore: fileStore,
            messages: Self.reconcileMessages,
            resumeTTL: resumeTTL
        )
    }

    private func reconcile(modelContext: ModelContext) throws -> AnalysisResumeContext? {
        let outcome = try reconciler.reconcile(
            recordSet.fetchRecords(modelContext: modelContext),
            modelContext: modelContext
        )
        duplicateRepairCount += outcome.repairedGroupCount
        return outcome.resumeContext
    }

    private func commit(
        episodeID: String,
        modelContext: ModelContext,
        resort: Bool = false
    ) throws {
        try recordSet.commit(episodeID: episodeID, modelContext: modelContext, resort: resort)
        notifyEpisodeStateChanged(episodeID)
    }

    private static let fetchDescriptors = AnalysisRecordFetchDescriptors<EpisodeAdAnalysisRecord>(
        all: {
            FetchDescriptor<EpisodeAdAnalysisRecord>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        },
        forEpisodeID: { targetEpisodeID in
            FetchDescriptor<EpisodeAdAnalysisRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetEpisodeID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        },
        forPodcastID: { targetPodcastID in
            FetchDescriptor<EpisodeAdAnalysisRecord>(
                predicate: #Predicate { record in
                    record.podcastID == targetPodcastID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        }
    )

    private func notifyEpisodeStateChanged(_ episodeID: String) {
        failures.stateChanges.notify()
        onEpisodeStateChanged?(episodeID)
    }

    private func ownsActiveRun(episodeID: String, runID: UUID) -> Bool {
        activeEpisodeID == episodeID && activeRunID == runID
    }
}
