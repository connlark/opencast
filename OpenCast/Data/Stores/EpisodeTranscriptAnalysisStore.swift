import Foundation
import Observation
import OpenCastAnalysis
import OpenCastTranscription
import SwiftData

@Observable
final class EpisodeTranscriptAnalysisStore {
    @ObservationIgnored private let recordSet = AnalysisRecordSet<EpisodeTranscriptAnalysisRecord>(descriptors: EpisodeTranscriptAnalysisStore.fetchDescriptors)
    /// The generate disclosure is this flow's only consent surface, so its
    /// acknowledgement lives in `LocalPreferenceRecord` with the rest of the
    /// wipeable local state: a data nuke deletes the row and the post-nuke
    /// reload resets this, making the next generate disclose again.
    private(set) var hasAcknowledgedGenerateDisclosure = false
    /// Episode-ID groups that held more than one record and were collapsed to
    /// a proven survivor, cumulative for this process (startup repair plus
    /// migration collisions). Diagnostics-only; never names episodes.
    private(set) var duplicateRepairCount = 0

    /// Drains jobs the analysis service accepted before this build ran the
    /// analysis on the device; nothing submits new work there.
    @ObservationIgnored private let client: any EpisodeTranscriptAnalysisClient
    @ObservationIgnored private let fileStore: EpisodeTranscriptAnalysisFileStore
    @ObservationIgnored private let poller: AnalysisJobPoller<EpisodeTranscriptAnalysisAPIResponse>
    /// How long an interrupted device run may resume with its run id.
    @ObservationIgnored private let resumeTTL: TimeInterval
    /// How long after acceptance a service job is still drained: the service
    /// keeps a finished result for a day.
    @ObservationIgnored private let serverJobDrainWindow: TimeInterval
    @ObservationIgnored private let resumeInitialPollAfter: TimeInterval
    @ObservationIgnored private let preparationGate: @Sendable () async throws -> Void
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    private var activeEpisodeID: String?
    @ObservationIgnored private var activeRunID: UUID?
    /// The run id the active device run sends under (its run record's id).
    @ObservationIgnored private var activeRequestRunID: String?
    /// The listener removed the active run's key in AI Services.
    @ObservationIgnored private var activeRunKeyRemoved = false
    @ObservationIgnored private let failures = AnalysisFailureSurface()
    @ObservationIgnored var onEpisodeStateChanged: ((String) -> Void)?
    /// Runs an analysis on the device. Set by the app model once its analysis
    /// members exist; tests inject a fake.
    @ObservationIgnored var producer: (any ChaptersSummaryProducing)?
    /// The dispatched run a `.running` record would resume, read from the
    /// run records.
    @ObservationIgnored var dispatchedRunLookup: (String) -> ChaptersSummaryDispatchedRun? = { _ in nil }
    /// Episodes with a Chapters & Summary run still open (dispatched or
    /// expired), read from the run records.
    @ObservationIgnored var openRunEpisodeIDs: () -> [String] = { [] }
    /// A run's background card expired and left its record `.running`. The
    /// app model resumes it at once when the app is already in the
    /// foreground; otherwise the next activation does.
    @ObservationIgnored var onRunInterrupted: ((ModelContext) -> Void)?

    init(
        fileStore: EpisodeTranscriptAnalysisFileStore = EpisodeTranscriptAnalysisFileStore(),
        configuration: TranscriptAnalysisBackendConfiguration = .current,
        transport: any EpisodeTranscriptAnalysisHTTPTransport & AppAttestHTTPTransport = URLSession.shared,
        preparationGate: @escaping @Sendable () async throws -> Void = {}
    ) {
        #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        client = URLSessionEpisodeTranscriptAnalysisClient(
            configuration: configuration,
            transport: transport
        )
        #else
        // Release resolves its lane from the StoreKit environment at first
        // use (sandbox installs must reach prod-staging), so no concrete
        // lane can be pinned here.
        client = TranscriptAnalysisRoutedAPIClient(clientFactory: { configuration in
            URLSessionEpisodeTranscriptAnalysisClient(
                configuration: configuration,
                transport: transport
            )
        })
        #endif
        self.fileStore = fileStore
        poller = Self.makePoller(timeout: .seconds(1_800)) { duration in
            try await Task.sleep(for: duration)
        }
        resumeTTL = 3_600
        serverJobDrainWindow = 86_400
        resumeInitialPollAfter = 1
        self.preparationGate = preparationGate
    }

    init(
        client: any EpisodeTranscriptAnalysisClient,
        fileStore: EpisodeTranscriptAnalysisFileStore = EpisodeTranscriptAnalysisFileStore(),
        pollingTimeout: Duration = .seconds(1_800),
        resumeTTL: TimeInterval = 3_600,
        serverJobDrainWindow: TimeInterval = 86_400,
        resumeInitialPollAfter: TimeInterval = 1,
        pollingSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        preparationGate: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.client = client
        self.fileStore = fileStore
        poller = Self.makePoller(timeout: pollingTimeout, sleep: pollingSleep)
        self.resumeTTL = resumeTTL
        self.serverJobDrainWindow = serverJobDrainWindow
        self.resumeInitialPollAfter = resumeInitialPollAfter
        self.preparationGate = preparationGate
    }

    deinit {
        activeTask?.cancel()
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

    func cancelActiveJob() {
        activeTask?.cancel()
    }

    /// Ends the active device run at once when it sends with the listener's
    /// key for `provider`, right after the listener removed that key in AI
    /// Services: its usage is counted, its run record fails as needing a
    /// key, and so does the episode's record, without the key screen (the
    /// listener is where keys are added). A trial run or a run on another
    /// provider goes on.
    func cancelActiveRun(onProvider provider: AnalysisProvider) {
        guard let activeTask,
              let runID = activeRequestRunID,
              producer?.stopForKeyRemoval(runID: runID, provider: provider) == true
        else {
            return
        }
        activeRunKeyRemoved = true
        activeTask.cancel()
    }

    func load(modelContext: ModelContext) {
        do {
            hasAcknowledgedGenerateDisclosure = try Self.isGenerateDisclosureAcknowledged(
                modelContext: modelContext
            )
            let resumeContext = try reconcile(modelContext: modelContext)
            try recordSet.reload(modelContext: modelContext)
            closeStrandedRuns(modelContext: modelContext)
            producer?.recordUnaccountedUsage(modelContext: modelContext)
            failures.reset()
            if let resumeContext {
                startResumingAnalysis(resumeContext, modelContext: modelContext)
            }
        } catch {
            failures.record(error)
        }
    }

    /// Closes every open run no `.running` record will resume, so no run
    /// record or kept reply outlives its analysis. A process that stopped
    /// between installing a document and closing its run left that run open:
    /// the installed document names it, and it closes as finished. Any other
    /// open run whose record is gone, failed or completed by another run
    /// closes as cancelled.
    private func closeStrandedRuns(modelContext: ModelContext) {
        guard let producer else {
            return
        }
        for episodeID in Set(openRunEpisodeIDs()) {
            guard let run = dispatchedRunLookup(episodeID) else {
                continue
            }
            let record = record(for: episodeID)
            if record?.state == .running, record?.jobAcceptedAt == nil {
                continue
            }
            if record?.state == .completed, document(for: episodeID)?.requestID == run.runID {
                producer.finishInstalled(runID: run.runID)
            } else {
                producer.abandon(runID: run.runID, modelContext: modelContext)
            }
        }
    }

    var records: [EpisodeTranscriptAnalysisRecord] {
        recordSet.records
    }

    func record(for episodeID: String) -> EpisodeTranscriptAnalysisRecord? {
        recordSet.record(for: episodeID)
    }

    /// Resolved by the store so the diagnostics sheet never duplicates the
    /// Application Support layout rules.
    func diagnosticsDocumentFileURL(for episodeID: String) -> URL? {
        record(for: episodeID)?.analysisRelativePath.map(fileStore.fileURL(relativePath:))
    }

    static let generateDisclosureAcknowledgedPreferenceKey = "transcriptAnalysis.generateDisclosureAcknowledged"
    private static let acknowledgedPreferenceValue = "true"

    func acknowledgeGenerateDisclosure(modelContext: ModelContext) {
        hasAcknowledgedGenerateDisclosure = true
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.generateDisclosureAcknowledgedPreferenceKey,
                value: Self.acknowledgedPreferenceValue,
                modelContext: modelContext
            )
            try modelContext.save()
        } catch {
            // The acknowledgement the user just gave stands for this
            // session; a failed persist only re-shows the disclosure on a
            // later launch.
        }
    }

    private static func isGenerateDisclosureAcknowledged(modelContext: ModelContext) throws -> Bool {
        try LocalPreferenceRecord.preference(
            forKey: generateDisclosureAcknowledgedPreferenceKey,
            modelContext: modelContext
        )?.value == acknowledgedPreferenceValue
    }

    func lastErrorMessage(for episodeID: String) -> String? {
        failures.message(for: episodeID)
    }

    /// Episodes whose `.running` record belongs to an interrupted device run
    /// (a background card expiry, or a relaunch that kept it), not to the
    /// run in flight or to a service job being drained.
    var resumableEpisodeIDs: [String] {
        records
            .filter { record in
                record.state == .running
                    && record.jobAcceptedAt == nil
                    && !isRunning(for: record.episodeID)
            }
            .map(\.episodeID)
    }

    func document(for episodeID: String) -> EpisodeTranscriptAnalysisDocument? {
        guard let record = record(for: episodeID),
              let relativePath = record.analysisRelativePath
        else {
            return nil
        }
        return try? fileStore.read(relativePath: relativePath)
    }

    func loadDocument(for episodeID: String) async throws -> EpisodeTranscriptAnalysisDocument {
        guard let record = record(for: episodeID),
              let relativePath = record.analysisRelativePath
        else {
            throw EpisodeTranscriptAnalysisError.analysisDocumentMissing
        }
        return try await fileStore.readOffCaller(relativePath: relativePath)
    }

    func isCurrentAnalysisDocument(
        _ analysisDocument: EpisodeTranscriptAnalysisDocument,
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
        _ analysisDocument: EpisodeTranscriptAnalysisDocument,
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
        // A contentless completed analysis is not a result worth keeping:
        // reporting it current would make every regenerate path skip.
        guard analysisDocument.hasPresentableContent else {
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
    ) -> EpisodeTranscriptAnalysisJobState {
        guard let document else {
            return .unavailable("Transcript unavailable.")
        }
        if isRunning(for: document.episodeID) {
            return .running
        }
        guard transcriptState == .completed else {
            return .unavailable(EpisodeTranscriptAnalysisError.transcriptNotCompleted.localizedDescription)
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
        analysisDocument: EpisodeTranscriptAnalysisDocument?
    ) async -> (jobState: EpisodeTranscriptAnalysisJobState, hasCurrentCompletedAnalysis: Bool) {
        guard let document else {
            return (.unavailable("Transcript unavailable."), false)
        }
        guard transcriptState == .completed else {
            return (
                .unavailable(EpisodeTranscriptAnalysisError.transcriptNotCompleted.localizedDescription),
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
        // hasPresentableContent keeps a completed-but-empty analysis out of
        // the "current" verdict, so the detail surface re-offers Generate
        // instead of rendering neither card.
        let hasCurrentCompletedAnalysis = analysisDocument.map {
            $0.hasPresentableContent && Self.isCurrentAnalysisDocument(
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
    ) -> EpisodeTranscriptAnalysisJobState {
        // Running is reported only for the episode the active task belongs
        // to. A store-global "any job active" signal here would mark every
        // other episode's detail as generating — and, because the detail
        // view invalidates on its own episode's isRunning flag, that false
        // state would outlive the job that caused it.
        if activeEpisodeID == document.episodeID && activeTask != nil {
            return .running
        }

        guard let record = record(for: document.episodeID) else {
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

    /// Titles are required (decision H2): they anchor summaries and the
    /// pinned prompt was validated with them present. Callers that cannot
    /// produce real titles must skip the run, never send nil.
    func startAnalysis(
        transcript document: EpisodeTranscriptDocument,
        episodeTitle: String,
        podcastTitle: String,
        transcriptState: EpisodeTranscriptState? = .completed,
        startedByListener: Bool = true,
        modelContext: ModelContext
    ) {
        guard activeTask == nil else {
            failures.record(EpisodeTranscriptAnalysisError.anotherJobActive, episodeID: document.episodeID)
            return
        }
        guard transcriptState == .completed else {
            failures.record(EpisodeTranscriptAnalysisError.transcriptNotCompleted, episodeID: document.episodeID)
            return
        }
        beginRun(
            transcript: document,
            episodeTitle: episodeTitle,
            podcastTitle: podcastTitle,
            resuming: nil,
            startedByListener: startedByListener,
            modelContext: modelContext
        )
    }

    /// Re-runs the interrupted device run of a `.running` record with its run
    /// id. A run that outlived the resume window, or whose run record is
    /// gone, ends the record as interrupted instead.
    func resumeAnalysis(
        transcript document: EpisodeTranscriptDocument,
        episodeTitle: String,
        podcastTitle: String,
        startedByListener: Bool = false,
        modelContext: ModelContext
    ) {
        guard activeTask == nil,
              resumableEpisodeIDs.contains(document.episodeID)
        else {
            return
        }
        guard let run = dispatchedRunLookup(document.episodeID),
              Date.now.timeIntervalSince(run.startedAt) <= resumeTTL
        else {
            abandonResume(episodeID: document.episodeID, modelContext: modelContext)
            return
        }
        beginRun(
            transcript: document,
            episodeTitle: episodeTitle,
            podcastTitle: podcastTitle,
            resuming: run,
            startedByListener: startedByListener,
            modelContext: modelContext
        )
    }

    /// Ends an interrupted device run that can no longer resume: its run
    /// record closes and the episode offers Generate again.
    func abandonResume(episodeID: String, modelContext: ModelContext) {
        guard resumableEpisodeIDs.contains(episodeID) else {
            return
        }
        if let run = dispatchedRunLookup(episodeID) {
            producer?.abandon(runID: run.runID, modelContext: modelContext)
        }
        markFailed(
            episodeID: episodeID,
            relativePath: nil,
            failure: Self.interruptedFailure,
            modelContext: modelContext
        )
    }

    private func beginRun(
        transcript document: EpisodeTranscriptDocument,
        episodeTitle: String,
        podcastTitle: String,
        resuming run: ChaptersSummaryDispatchedRun?,
        startedByListener: Bool,
        modelContext: ModelContext
    ) {
        failures.clear(episodeID: document.episodeID)
        let ownerID = UUID()
        let requestRunID = run?.runID ?? UUID().uuidString
        activeEpisodeID = document.episodeID
        activeRunID = ownerID
        activeRequestRunID = requestRunID
        activeRunKeyRemoved = false
        activeTask = Task {
            await runAnalysis(
                ownerID: ownerID,
                requestRunID: requestRunID,
                transcript: document,
                episodeTitle: episodeTitle,
                podcastTitle: podcastTitle,
                resuming: run,
                startedByListener: startedByListener,
                modelContext: modelContext
            )
        }
        failures.stateChanges.notify()
        notifyEpisodeStateChanged(document.episodeID)
    }

    func deleteAnalysis(episodeID: String, modelContext: ModelContext) {
        if activeEpisodeID == episodeID {
            activeTask?.cancel()
        } else if let run = dispatchedRunLookup(episodeID) {
            // Whatever state the record reached, its open run and kept
            // reply go with it.
            producer?.abandon(runID: run.runID, modelContext: modelContext)
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
            } else if let run = dispatchedRunLookup(record.episodeID) {
                producer?.abandon(runID: run.runID, modelContext: modelContext)
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
        let newDirectory = "\(EpisodeTranscriptAnalysisFileStore.directoryName)/\(fileStore.safeStem(newEpisodeID))"
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
        ownerID: UUID,
        requestRunID: String,
        transcript document: EpisodeTranscriptDocument,
        episodeTitle: String,
        podcastTitle: String,
        resuming run: ChaptersSummaryDispatchedRun?,
        startedByListener: Bool,
        modelContext: ModelContext
    ) async {
        var isInterrupted = false
        defer {
            if ownsActiveRun(episodeID: document.episodeID, runID: ownerID) {
                activeTask = nil
                activeEpisodeID = nil
                activeRunID = nil
                activeRequestRunID = nil
                activeRunKeyRemoved = false
                failures.stateChanges.notify()
                if isInterrupted {
                    onRunInterrupted?(modelContext)
                }
            }
        }

        guard !Task.isCancelled else {
            endCancelledRun(resuming: run, episodeID: document.episodeID, modelContext: modelContext)
            return
        }
        guard let producer else {
            failures.record(EpisodeTranscriptAnalysisError.clientDisabled, episodeID: document.episodeID)
            return
        }

        var relativePath: String?
        do {
            let preparation = try await prepareAnalysis(
                transcript: document,
                episodeTitle: episodeTitle,
                podcastTitle: podcastTitle,
                runID: requestRunID,
                isResume: run != nil,
                startedByListener: startedByListener
            )
            relativePath = preparation.relativePath
            try Task.checkCancellation()
            guard ownsActiveRun(episodeID: document.episodeID, runID: ownerID) else {
                throw CancellationError()
            }
            if let run, run.transcriptFingerprint != preparation.fingerprint {
                // The transcript changed under the interrupted run: its
                // answer would describe other text.
                producer.abandon(runID: run.runID, modelContext: modelContext)
                markFailed(
                    episodeID: document.episodeID,
                    relativePath: nil,
                    failure: Self.interruptedFailure,
                    modelContext: modelContext
                )
                return
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
                chapterCount: 0,
                warningCount: 0,
                errorMessage: nil,
                modelContext: modelContext
            )
            try commit(episodeID: document.episodeID, modelContext: modelContext, resort: true)

            let result = await producer.run(preparation.request, modelContext: modelContext)
            try Task.checkCancellation()
            guard ownsActiveRun(episodeID: document.episodeID, runID: ownerID) else {
                throw CancellationError()
            }

            switch result {
            case .completed(let response, let completion):
                // Closing the run deletes its kept reply, so it waits until
                // the document is installed.
                let analysisDocument = makeDocument(
                    transcript: document,
                    response: response,
                    fingerprint: preparation.fingerprint,
                    transcriptSegmentCount: preparation.segments.count
                )
                do {
                    try completeAnalysis(
                        episodeID: document.episodeID,
                        fingerprint: preparation.fingerprint,
                        relativePath: preparation.relativePath,
                        document: analysisDocument,
                        response: response,
                        modelContext: modelContext
                    )
                } catch is CancellationError {
                    // The record was deleted or its transcript changed:
                    // nothing is left to install the answer into.
                    producer.abandon(runID: completion.runID, modelContext: modelContext)
                    throw CancellationError()
                } catch let error as EpisodeTranscriptAnalysisHTTPError {
                    // The answer's contract is not this build's.
                    producer.fail(completion, code: .unsupportedSchemaVersion)
                    throw error
                } catch {
                    // A storage failure: the run stays open with its reply
                    // kept and the record stays running, so the next launch
                    // or activation installs the answer without another send.
                    failures.record(error, episodeID: document.episodeID)
                    return
                }
                producer.finish(completion)
                failures.clear(episodeID: document.episodeID)
            case .failed(let failure):
                markFailed(
                    episodeID: document.episodeID,
                    relativePath: relativePath,
                    failure: failure,
                    modelContext: modelContext
                )
            case .expired:
                // The record stays `.running` and the run resumes with the
                // same id.
                isInterrupted = true
            case .cancelled:
                endCancelledRun(resuming: run, episodeID: document.episodeID, modelContext: modelContext)
            }
        } catch is CancellationError {
            endCancelledRun(resuming: run, episodeID: document.episodeID, modelContext: modelContext)
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
        transcript document: EpisodeTranscriptDocument,
        episodeTitle: String,
        podcastTitle: String,
        runID: String,
        isResume: Bool,
        startedByListener: Bool
    ) async throws -> EpisodeTranscriptAnalysisPreparation {
        try await preparationGate()
        try Task.checkCancellation()

        let segments = OpenCastTranscriptSegmentNormalizer.normalized(document.segments)
        guard !segments.isEmpty else {
            throw EpisodeTranscriptAnalysisError.transcriptNotCompleted
        }
        let fingerprint = fileStore.transcriptFingerprint(
            for: document,
            segments: segments
        )
        let relativePath = fileStore.relativePath(
            episodeID: document.episodeID,
            transcriptFingerprint: fingerprint
        )
        let request = ChaptersSummaryRunRequest(
            runID: runID,
            isResume: isResume,
            startedByListener: startedByListener,
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            episodeTitle: episodeTitle,
            transcriptFingerprint: fingerprint,
            analysisRequest: Self.makeRequest(
                transcript: document,
                episodeTitle: episodeTitle,
                podcastTitle: podcastTitle,
                segments: segments,
                fingerprint: fingerprint,
                requestID: runID
            )
        )
        try Task.checkCancellation()

        return EpisodeTranscriptAnalysisPreparation(
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
        // A service job sends nothing with the listener's key.
        activeRequestRunID = nil
        activeRunKeyRemoved = false
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
                initialPollAfter: resumeInitialPollAfter
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

    private func pollUntilCompleted(
        jobID: String,
        initialPollAfter: TimeInterval
    ) async throws -> EpisodeTranscriptAnalysisAPIResponse {
        try await poller.pollUntilCompleted(
            jobID: jobID,
            initialPollAfter: initialPollAfter,
            poll: { [client] jobID in
                try await client.pollJob(id: jobID)
            },
            resubmit: nil
        )
    }

    private static func makePoller(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) -> AnalysisJobPoller<EpisodeTranscriptAnalysisAPIResponse> {
        AnalysisJobPoller(
            timeout: timeout,
            sleep: sleep,
            isTransientJobFailure: {
                ($0 as? EpisodeTranscriptAnalysisHTTPError)?.isTransientJobFailure == true
            },
            isTransientPollFailure: {
                ($0 as? EpisodeTranscriptAnalysisHTTPError)?.isTransientPollFailure == true
            },
            timedOutError: EpisodeTranscriptAnalysisError.analysisTimedOut,
            jobIDMismatchError: jobIDMismatchError()
        )
    }

    private func completeAnalysis(
        episodeID: String,
        fingerprint: String,
        relativePath: String,
        document: EpisodeTranscriptAnalysisDocument,
        response: EpisodeTranscriptAnalysisAPIResponse,
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

        // A response from any policy other than the pinned one cannot be
        // trusted to present chapters or a summary; fail cleanly so callers
        // fall back to a fresh analysis once the client understands it.
        guard response.policy == EpisodeTranscriptAnalysisContract.expectedPolicy,
              response.schemaVersion == EpisodeTranscriptAnalysisContract.schemaVersion
        else {
            throw EpisodeTranscriptAnalysisHTTPError(
                statusCode: -1,
                code: "unexpected_contract",
                detail: "\(response.policy) schema \(response.schemaVersion)"
            )
        }

        try fileStore.write(document, relativePath: relativePath)
        record.state = .completed
        record.analysisRelativePath = relativePath
        record.model = response.model
        record.policy = response.policy
        record.chapterCount = response.chapters.count
        record.warningCount = response.warnings.count
        record.errorMessage = nil
        record.failureKind = nil
        record.jobAcceptedAt = nil
        record.updatedAt = .now
        try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
    }

    private static func jobIDMismatchError() -> EpisodeTranscriptAnalysisHTTPError {
        EpisodeTranscriptAnalysisHTTPError(statusCode: -1, code: "job_id_mismatch", detail: nil)
    }

    private nonisolated static func makeRequest(
        transcript document: EpisodeTranscriptDocument,
        episodeTitle: String,
        podcastTitle: String,
        segments: [OpenCastTranscriptSegment],
        fingerprint: String,
        requestID: String
    ) -> TranscriptAnalysisRequest {
        TranscriptAnalysisRequest(
            requestID: requestID,
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            episodeTitle: episodeTitle,
            podcastTitle: podcastTitle,
            transcript: TranscriptAnalysisTranscript(
                languageCode: document.languageCode,
                audioDuration: document.audioDuration,
                modelIdentifier: document.modelIdentifier,
                modelVersion: document.modelVersion,
                modelTreeSHA256: document.modelTreeSHA256,
                fingerprint: fingerprint,
                updatedAt: document.updatedAt.formatted(.iso8601),
                state: EpisodeTranscriptAnalysisContract.completedTranscriptState,
                segmentCount: segments.count
            ),
            segments: segments.map { segment in
                AnalysisSegment(
                    id: Int64(segment.id),
                    start: segment.start,
                    end: segment.end,
                    text: segment.text
                )
            }
        )
    }

    private func makeDocument(
        transcript document: EpisodeTranscriptDocument,
        response: EpisodeTranscriptAnalysisAPIResponse,
        fingerprint: String,
        transcriptSegmentCount: Int
    ) -> EpisodeTranscriptAnalysisDocument {
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
        response: EpisodeTranscriptAnalysisAPIResponse,
        fingerprint: String,
        transcriptSegmentCount: Int
    ) -> EpisodeTranscriptAnalysisDocument {
        EpisodeTranscriptAnalysisDocument(
            schemaVersion: EpisodeTranscriptAnalysisContract.schemaVersion,
            episodeID: episodeID,
            podcastID: podcastID,
            requestID: response.requestID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcriptUpdatedAt,
            transcriptSegmentCount: transcriptSegmentCount,
            transcriptState: .completed,
            model: response.model,
            policy: response.policy,
            chapters: response.chapters.enumerated().map { index, chapter in
                EpisodeTranscriptAnalysisChapter(
                    id: index,
                    title: chapter.title,
                    startSegmentID: chapter.startSegmentID,
                    endSegmentID: chapter.endSegmentID,
                    startTime: chapter.startTime,
                    endTime: chapter.endTime,
                    confidence: chapter.confidence
                )
            },
            summary: response.summary.map { summary in
                EpisodeTranscriptAnalysisSummary(
                    summary: summary.summary,
                    oneLineDescription: summary.oneLineDescription,
                    claims: summary.claims.map { claim in
                        EpisodeTranscriptAnalysisClaim(
                            text: claim.text,
                            evidenceSegmentID: claim.evidenceSegmentID
                        )
                    }
                )
            },
            warnings: response.warnings,
            usage: response.usage.map { usage in
                EpisodeTranscriptAnalysisUsage(
                    promptTokenCount: usage.promptTokenCount,
                    candidatesTokenCount: usage.candidatesTokenCount,
                    thoughtsTokenCount: usage.thoughtsTokenCount,
                    totalTokenCount: usage.totalTokenCount
                )
            },
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func isUsableCurrentRecord(
        _ record: EpisodeTranscriptAnalysisRecord,
        for document: EpisodeTranscriptDocument,
        transcriptFingerprint: String,
        transcriptSegmentCount: Int
    ) -> Bool {
        // Whole-second comparison: the transcript's `updatedAt` loses its
        // fractional seconds on the `.iso8601` disk round trip, while the
        // SwiftData record keeps full precision, so exact equality would
        // brand a record seeded from an in-memory document permanently stale.
        (record.state != .completed || record.policy == EpisodeTranscriptAnalysisContract.expectedPolicy)
            && record.transcriptFingerprint == transcriptFingerprint
            && record.transcriptUpdatedAt.truncatedToWholeSeconds == document.updatedAt.truncatedToWholeSeconds
            && record.transcriptSegmentCount == transcriptSegmentCount
            && record.transcriptState == .completed
            // A failed first attempt has no output document. Its error still
            // belongs to these transcript inputs and must remain retryable.
            && (record.state != .completed || fileStore.documentExists(relativePath: record.analysisRelativePath))
    }

    private nonisolated static func isCurrentAnalysisDocument(
        _ analysisDocument: EpisodeTranscriptAnalysisDocument,
        for transcriptDocument: EpisodeTranscriptDocument,
        transcriptFingerprint: String,
        transcriptSegmentCount: Int
    ) -> Bool {
        analysisDocument.policy == EpisodeTranscriptAnalysisContract.expectedPolicy
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
        chapterCount: Int,
        warningCount: Int,
        errorMessage: String?,
        modelContext: ModelContext
    ) throws -> EpisodeTranscriptAnalysisRecord {
        let matchingRecords = try recordSet.fetchRecords(episodeID: episodeID, modelContext: modelContext)
        let record: EpisodeTranscriptAnalysisRecord
        if let existingRecord = matchingRecords.first {
            record = existingRecord
        } else {
            record = EpisodeTranscriptAnalysisRecord(
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
        record.chapterCount = chapterCount
        record.warningCount = warningCount
        record.errorMessage = errorMessage
        record.failureKind = nil
        record.jobAcceptedAt = nil
        record.updatedAt = .now
        return record
    }

    /// A drained service job, or the store's own document write, failed.
    private func markFailed(
        episodeID: String,
        relativePath: String?,
        error: Error,
        modelContext: ModelContext
    ) {
        persistFailure(
            episodeID: episodeID,
            relativePath: relativePath,
            kind: .generic,
            message: Self.failureMessage(for: error),
            modelContext: modelContext
        )
    }

    /// A service error keeps only its code, and only when it is a plain
    /// identifier: its detail text never reaches the record.
    private static func failureMessage(for error: Error) -> String {
        guard let serviceError = error as? EpisodeTranscriptAnalysisHTTPError else {
            return error.localizedDescription
        }
        let code = serviceError.code
        let isPlainCode = (1...64).contains(code.count)
            && code.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
            }
        return "Chapters & Summary failed (\(isPlainCode ? code : "service_error"))."
    }

    private func markFailed(
        episodeID: String,
        relativePath: String?,
        failure: ChaptersSummaryRunFailure,
        modelContext: ModelContext
    ) {
        persistFailure(
            episodeID: episodeID,
            relativePath: relativePath,
            kind: failure.kind,
            message: failure.message,
            modelContext: modelContext
        )
    }

    private func persistFailure(
        episodeID: String,
        relativePath: String?,
        kind: EpisodeAnalysisFailureKind,
        message: String,
        modelContext: ModelContext
    ) {
        do {
            guard let record = try recordSet.fetchStoredRecord(episodeID: episodeID, modelContext: modelContext) else {
                failures.record(message: message, episodeID: episodeID)
                return
            }
            record.state = .failed
            record.errorMessage = message
            record.failureKind = kind
            record.jobAcceptedAt = nil
            record.analysisRelativePath = relativePath ?? record.analysisRelativePath
            record.updatedAt = .now
            try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
            failures.record(message: message, episodeID: episodeID)
        } catch {
            failures.record(error, episodeID: episodeID)
        }
    }

    /// A cancelled run never resumes, at whatever point it stopped: a resumed
    /// run's record closes even when the cancellation came before the
    /// producer saw it. Delete and the data nuke remove the episode's record
    /// themselves; any other cancellation ends a record it left `.running`
    /// so the episode offers Generate again. A run whose key the listener
    /// removed in AI Services closes as needing a key, and its record fails
    /// as when a send finds the key gone, so its card and queue row say so.
    private func endCancelledRun(
        resuming run: ChaptersSummaryDispatchedRun?,
        episodeID: String,
        modelContext: ModelContext
    ) {
        let keyRemoved = activeRunKeyRemoved
        if let runID = keyRemoved ? activeRequestRunID : run?.runID {
            producer?.abandon(runID: runID, modelContext: modelContext)
        }
        guard let record = try? recordSet.fetchStoredRecord(episodeID: episodeID, modelContext: modelContext),
              record.state == .running,
              record.jobAcceptedAt == nil
        else {
            return
        }
        if keyRemoved {
            markFailed(episodeID: episodeID, relativePath: nil, failure: Self.keyRemovedFailure, modelContext: modelContext)
            return
        }
        record.state = .failed
        record.errorMessage = Self.interruptedFailure.message
        record.failureKind = Self.interruptedFailure.kind
        record.updatedAt = .now
        try? commit(episodeID: episodeID, modelContext: modelContext, resort: true)
    }

    private static let interruptedFailure = ChaptersSummaryFailureMapping.interrupted
    private static let keyRemovedFailure = ChaptersSummaryFailureMapping.failure(keyRequired: .noKey)

    private static let reconcileMessages = AnalysisRecordReconcileMessages(
        interrupted: "Chapters & Summary was interrupted.",
        documentMissing: "Chapters & Summary document is missing.",
        transcriptMismatch: "Chapters & Summary no longer matches the transcript."
    )

    private var reconciler: AnalysisRecordReconciler<EpisodeTranscriptAnalysisRecord> {
        let dispatchedRunLookup = dispatchedRunLookup
        let resumeTTL = resumeTTL
        return AnalysisRecordReconciler(
            fileStore: fileStore,
            messages: Self.reconcileMessages,
            resumeTTL: serverJobDrainWindow,
            // Chapters & Summary no longer defers on a daily cap or on
            // credit: a record an earlier build left deferred is a plain
            // failure, and the episode offers Generate again.
            repairFailedRecord: { record, now in
                guard record.failureKind == .capExceeded || record.failureKind == .insufficientSeconds else {
                    return false
                }
                record.failureKind = .generic
                record.updatedAt = now
                return true
            },
            resumesDeviceRun: { record, now in
                guard let run = dispatchedRunLookup(record.episodeID) else {
                    return false
                }
                return run.transcriptFingerprint == record.transcriptFingerprint
                    && now.timeIntervalSince(run.startedAt) <= resumeTTL
            }
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

    private static let fetchDescriptors = AnalysisRecordFetchDescriptors<EpisodeTranscriptAnalysisRecord>(
        all: {
            FetchDescriptor<EpisodeTranscriptAnalysisRecord>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        },
        forEpisodeID: { targetEpisodeID in
            FetchDescriptor<EpisodeTranscriptAnalysisRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetEpisodeID
                },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        },
        forPodcastID: { targetPodcastID in
            FetchDescriptor<EpisodeTranscriptAnalysisRecord>(
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
