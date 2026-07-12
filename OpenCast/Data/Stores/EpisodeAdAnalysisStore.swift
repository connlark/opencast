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
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var activeEpisodeID: String?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private let stateChanges = StoreChangeNotifier()
    @ObservationIgnored var onEpisodeStateChanged: ((String) -> Void)?

    init(
        fileStore: EpisodeAdAnalysisFileStore = EpisodeAdAnalysisFileStore(),
        configuration: AdAnalysisBackendConfiguration = .current,
        transport: any EpisodeAdAnalysisHTTPTransport & AppAttestHTTPTransport = URLSession.shared
    ) {
        client = URLSessionEpisodeAdAnalysisClient(
            configuration: configuration,
            transport: transport
        )
        self.fileStore = fileStore
        analysisUnavailableMessage = configuration.analysisUnavailableMessage
    }

    init(
        client: any EpisodeAdAnalysisClient,
        fileStore: EpisodeAdAnalysisFileStore = EpisodeAdAnalysisFileStore(),
        analysisUnavailableMessage: String? = nil
    ) {
        self.client = client
        self.fileStore = fileStore
        self.analysisUnavailableMessage = analysisUnavailableMessage
    }

    deinit {
        activeTask?.cancel()
    }

    var canStartAnalysis: Bool {
        analysisUnavailableMessage == nil
    }

    var hasActiveJob: Bool {
        activeTask != nil
    }

    var changeSequence: Int {
        stateChanges.sequence
    }

    func waitForChange(after sequence: Int) async throws {
        try await stateChanges.wait(after: sequence)
    }

    func load(modelContext: ModelContext) {
        do {
            try reconcile(modelContext: modelContext)
            try reload(modelContext: modelContext)
            lastErrorMessage = nil
            lastErrorEpisodeID = nil
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
        return analysisDocument.policy == EpisodeAdAnalysisContract.expectedPolicy
            && analysisDocument.transcriptFingerprint == fileStore.transcriptFingerprint(
                for: transcriptDocument,
                segments: segments
            )
            && analysisDocument.transcriptUpdatedAt == transcriptDocument.updatedAt
            && analysisDocument.transcriptSegmentCount == segments.count
            && analysisDocument.transcriptState == .completed
    }

    func jobState(
        for document: EpisodeTranscriptDocument?,
        transcriptState: EpisodeTranscriptState? = .completed
    ) -> EpisodeAdAnalysisJobState {
        guard let document else {
            return .unavailable("Transcript unavailable.")
        }
        guard transcriptState == .completed else {
            return .unavailable(EpisodeAdAnalysisError.transcriptNotCompleted.localizedDescription)
        }
        guard !normalizedSegments(for: document).isEmpty else {
            return .unavailable("Transcript has no segments.")
        }

        if activeEpisodeID == document.episodeID && activeTask != nil {
            return .running
        }

        guard let record = record(for: document.episodeID) else {
            if let analysisUnavailableMessage {
                return .unavailable(analysisUnavailableMessage)
            }
            return .ready
        }

        let isStale = !isUsableCurrentRecord(record, for: document)
        switch record.state {
        case .queued, .running:
            return .running
        case .completed:
            return .completed(record, isStale: isStale)
        case .failed:
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
        let segments = normalizedSegments(for: document)
        guard !segments.isEmpty else {
            recordFailure(EpisodeAdAnalysisError.transcriptNotCompleted, episodeID: document.episodeID)
            return
        }

        clearFailure(episodeID: document.episodeID)
        let fingerprint = fileStore.transcriptFingerprint(for: document, segments: segments)
        let relativePath = fileStore.relativePath(
            episodeID: document.episodeID,
            transcriptFingerprint: fingerprint
        )
        do {
            try upsertRecord(
                episodeID: document.episodeID,
                podcastID: document.podcastID,
                transcriptFingerprint: fingerprint,
                transcriptUpdatedAt: document.updatedAt,
                transcriptSegmentCount: segments.count,
                transcriptState: .completed,
                state: .running,
                analysisRelativePath: relativePath,
                model: "",
                policy: "",
                spanCount: 0,
                warningCount: 0,
                errorMessage: nil,
                modelContext: modelContext
            )
            try commit(episodeID: document.episodeID, modelContext: modelContext, resort: true)
        } catch {
            recordFailure(error, episodeID: document.episodeID)
            return
        }

        let runID = UUID()
        activeEpisodeID = document.episodeID
        activeRunID = runID
        activeTask = Task {
            await runAnalysis(
                runID: runID,
                transcript: document,
                segments: segments,
                modelContext: modelContext
            )
        }
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
        segments: [OpenCastTranscriptSegment],
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

        let fingerprint = fileStore.transcriptFingerprint(for: document, segments: segments)
        let relativePath = fileStore.relativePath(
            episodeID: document.episodeID,
            transcriptFingerprint: fingerprint
        )

        do {
            let request = makeRequest(
                transcript: document,
                segments: segments,
                fingerprint: fingerprint,
                requestID: UUID().uuidString
            )
            let response = try await client.analyze(request)
            try Task.checkCancellation()
            guard ownsActiveRun(episodeID: document.episodeID, runID: runID) else {
                throw CancellationError()
            }

            let analysisDocument = makeDocument(
                transcript: document,
                response: response,
                fingerprint: fingerprint,
                transcriptSegmentCount: segments.count
            )
            guard let record = try fetchStoredRecord(
                episodeID: document.episodeID,
                modelContext: modelContext
            ) else {
                throw CancellationError()
            }
            try fileStore.write(analysisDocument, relativePath: relativePath)

            record.state = .completed
            record.analysisRelativePath = relativePath
            record.model = response.model
            record.policy = response.policy
            record.spanCount = response.spans.count
            record.warningCount = response.warnings.count
            record.errorMessage = nil
            record.failureKind = nil
            record.updatedAt = .now
            try commit(episodeID: document.episodeID, modelContext: modelContext, resort: true)
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

    private func makeRequest(
        transcript document: EpisodeTranscriptDocument,
        segments: [OpenCastTranscriptSegment],
        fingerprint: String,
        requestID: String
    ) -> EpisodeAdAnalysisAPIRequest {
        return EpisodeAdAnalysisAPIRequest(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            requestID: requestID,
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            episodeTitle: nil,
            podcastTitle: nil,
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
        EpisodeAdAnalysisDocument(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            requestID: response.requestID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: document.updatedAt,
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
        for document: EpisodeTranscriptDocument
    ) -> Bool {
        let segments = normalizedSegments(for: document)
        // A completed record from a pre-`promo_ad_breaks_v2` policy is
        // outdated even when its transcript still matches: the old contract's
        // cue-fragment spans must never render or skip again.
        return (record.state != .completed || record.policy == EpisodeAdAnalysisContract.expectedPolicy)
            && record.transcriptFingerprint == fileStore.transcriptFingerprint(
                for: document,
                segments: segments
            )
            && record.transcriptUpdatedAt == document.updatedAt
            && record.transcriptSegmentCount == segments.count
            && record.transcriptState == .completed
            && fileStore.documentExists(relativePath: record.analysisRelativePath)
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

    private func reconcile(modelContext: ModelContext) throws {
        let fetchedRecords = try fetchRecords(modelContext: modelContext)
        var changed = false
        for record in fetchedRecords {
            switch record.state {
            case .queued, .running:
                record.state = .failed
                record.errorMessage = "Promo/ad analysis was interrupted."
                record.updatedAt = .now
                changed = true
            case .completed:
                guard fileStore.documentExists(relativePath: record.analysisRelativePath) else {
                    record.state = .failed
                    record.errorMessage = "Promo/ad analysis document is missing."
                    record.updatedAt = .now
                    changed = true
                    continue
                }
            case .failed:
                break
            }
        }

        if changed {
            try modelContext.save()
        }
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
