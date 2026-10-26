import CryptoKit
import Foundation
import Observation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastTranscription
import SwiftData

/// Promo and ad analysis of each episode's transcript. A new analysis runs
/// on the device, on the route its run environment resolves (the
/// listener's key or the trial), under a run record written before its
/// first send. A job an earlier build started on opencast's analysis
/// service is still polled to completion at launch, and never resubmitted.
@Observable
final class EpisodeAdAnalysisStore {
    @ObservationIgnored private let recordSet = AnalysisRecordSet<EpisodeAdAnalysisRecord>(descriptors: EpisodeAdAnalysisStore.fetchDescriptors)
    /// Episode-ID groups that held more than one record and were collapsed to
    /// a proven survivor, cumulative for this process (startup repair plus
    /// migration collisions). Diagnostics-only; never names episodes.
    private(set) var duplicateRepairCount = 0

    /// Routes, transports, run records, usage and the key screen for device
    /// runs. The app model sets it once its analysis members exist; without
    /// one nothing starts.
    @ObservationIgnored var runEnvironment: (any EpisodeAdAnalysisRunEnvironment)?
    /// Polls jobs an earlier build started; never submits.
    @ObservationIgnored private let client: any EpisodeAdAnalysisClient
    @ObservationIgnored private let fileStore: EpisodeAdAnalysisFileStore
    @ObservationIgnored private let poller: AnalysisJobPoller<EpisodeAdAnalysisAPIResponse>
    @ObservationIgnored private let resumeTTL: TimeInterval
    @ObservationIgnored private let resumeInitialPollAfter: TimeInterval
    @ObservationIgnored private let preparationGate: @Sendable () async throws -> Void
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    private var activeEpisodeID: String?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var activeCancelReason: EpisodeAdAnalysisCancelReason?
    /// The provider of the active run when it sends with the listener's key.
    @ObservationIgnored private(set) var activeDirectProvider: AnalysisProvider?
    /// Episodes whose last run ended because the listener removed its key
    /// in AI Services; cleared when the episode's next run starts.
    @ObservationIgnored private var keyRemovedEpisodeIDs: Set<String> = []
    /// The active device run's steps; observed so progress surfaces follow.
    private var activeProgress: AdAnalysisRunProgress?
    @ObservationIgnored private let failures = AnalysisFailureSurface()
    @ObservationIgnored var onEpisodeStateChanged: ((String) -> Void)?

    init(
        fileStore: EpisodeAdAnalysisFileStore = EpisodeAdAnalysisFileStore(),
        configuration: AdAnalysisBackendConfiguration? = nil,
        transport: any EpisodeAdAnalysisHTTPTransport & AppAttestHTTPTransport = URLSession.shared,
        preparationGate: @escaping @Sendable () async throws -> Void = {}
    ) {
        #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        client = URLSessionEpisodeAdAnalysisClient(configuration: configuration ?? .current, transport: transport)
        #else
        if let configuration {
            client = URLSessionEpisodeAdAnalysisClient(configuration: configuration, transport: transport)
        } else {
            client = EpisodeAdAnalysisRoutedClient(clientFactory: { configuration in
                URLSessionEpisodeAdAnalysisClient(configuration: configuration, transport: transport)
            })
        }
        #endif
        self.fileStore = fileStore
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
        runEnvironment: (any EpisodeAdAnalysisRunEnvironment)? = nil,
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
        self.runEnvironment = runEnvironment
        poller = Self.makePoller(timeout: pollingTimeout, sleep: pollingSleep)
        self.resumeTTL = resumeTTL
        self.resumeInitialPollAfter = resumeInitialPollAfter
        self.preparationGate = preparationGate
    }

    deinit {
        activeTask?.cancel()
    }

    /// Whether a run can start at all; its route is decided when it runs.
    var canStartAnalysis: Bool {
        runEnvironment != nil
    }

    var analysisStartUnavailableMessage: String? {
        runEnvironment == nil ? EpisodeAdAnalysisError.clientDisabled.localizedDescription : nil
    }

    var hasActiveJob: Bool {
        activeTask != nil
    }

    func isRunning(for episodeID: String) -> Bool {
        activeEpisodeID == episodeID && activeTask != nil
    }

    /// Whether the episode's last run ended because the listener removed
    /// its key in AI Services, so nothing needs to show the key screen.
    func endedForKeyRemoval(episodeID: String) -> Bool {
        keyRemovedEpisodeIDs.contains(episodeID)
    }

    /// The active device run's steps for `episodeID`; `nil` while no device
    /// run of the episode is active (or before its route is resolved).
    func analysisProgress(for episodeID: String) -> AdAnalysisRunProgress? {
        activeEpisodeID == episodeID ? activeProgress : nil
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

    /// Stops the active run without waiting for it. A device run the
    /// listener stopped ends its run record cancelled; one whose card
    /// expired stays resumable by the episode's next start or the next
    /// launch. Either way the episode's record stays running until a start
    /// or a launch moves it on. A run whose key the listener removed ends
    /// as needing a key at once, its episode's record and run record failed.
    func cancelActiveRun(reason: EpisodeAdAnalysisCancelReason) {
        guard let activeTask else {
            return
        }
        activeCancelReason = reason
        activeTask.cancel()
    }

    /// Reconciles the records the last process left. One run resumes: a job
    /// an earlier build started resumes polling, or a device run killed
    /// after dispatch resumes under its run id, answering the windows it
    /// already had answered from its kept replies. No launch starts a new
    /// run. A run killed after its document was installed is finished.
    func load(modelContext: ModelContext) {
        do {
            let resume = try reconcile(modelContext: modelContext)
            try recordSet.reload(modelContext: modelContext)
            finishInstalledRuns(modelContext: modelContext)
            recordUnaccountedUsage(modelContext: modelContext)
            failures.reset()
            if let job = resume.job {
                startResumingAnalysis(job, modelContext: modelContext)
            } else if let device = resume.device {
                startResumingDeviceRun(device, modelContext: modelContext)
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
        if let message = failures.message(for: episodeID) { return message }
        guard let state = try? fileStore.readRunState(episodeID: episodeID), let failure = state.failure else { return nil }
        return EpisodeAdAnalysisHTTPError(statusCode: 422, code: state.failureCode ?? "ad_analysis_incomplete", detail: nil, failure: failure).localizedDescription
    }

    func automaticReplayError(for transcript: EpisodeTranscriptDocument) async throws -> EpisodeAdAnalysisHTTPError? {
        guard let state = try fileStore.readRunState(episodeID: transcript.episodeID),
              let failure = state.failure, failure.suppressesAutomaticReplay,
              state.replayIdentity == (try await EpisodeAdAnalysisRunState.inputIdentity(transcript))
        else { return nil }
        // A failure retained under another revision (or a legacy one with
        // none) gets one opportunity under the active bundle's revision; the
        // next failure records it.
        if let revision = runEnvironment?.adDetectionPolicyRevision, revision != failure.policyRevision { return nil }
        return EpisodeAdAnalysisHTTPError(statusCode: 422, code: state.failureCode ?? "ad_analysis_incomplete", detail: nil, failure: failure)
    }

    func retainFailure(_ error: EpisodeAdAnalysisHTTPError, transcript: EpisodeTranscriptDocument) async throws {
        guard var failure = error.replayFailure else { return }
        if failure.policyRevision == nil { failure.policyRevision = runEnvironment?.adDetectionPolicyRevision }
        let identity = try await EpisodeAdAnalysisRunState.inputIdentity(transcript)
        try Task.checkCancellation()
        var state = try fileStore.readRunState(episodeID: transcript.episodeID)
            ?? EpisodeAdAnalysisRunState(transcriptFingerprint: "")
        state.replayIdentity = identity
        state.failure = failure
        state.failureCode = error.code
        try fileStore.writeRunState(state, episodeID: transcript.episodeID)
        failures.record(error, episodeID: transcript.episodeID)
    }

    func document(for episodeID: String) -> EpisodeAdAnalysisDocument? {
        guard let record = record(for: episodeID),
              let relativePath = record.analysisRelativePath
        else {
            return nil
        }
        return try? fileStore.read(relativePath: relativePath)
    }

    func loadDocument(
        for episodeID: String,
        transcript: EpisodeTranscriptDocument? = nil
    ) async throws -> EpisodeAdAnalysisDocument {
        guard let record = record(for: episodeID),
              let relativePath = record.analysisRelativePath
        else {
            throw EpisodeAdAnalysisError.analysisDocumentMissing
        }
        let document = try await fileStore.readOffCaller(relativePath: relativePath)
        guard let transcript,
              await isCurrentAnalysisDocumentOffCaller(document, for: transcript)
        else { return document }
        return await EpisodeAdBoundaryRefiner.refined(document, transcript: transcript)
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

        // The route is decided when a run starts, so an episode without a
        // record can always start one.
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

    /// Starts a device run for `document`. `retryFailed` false (an automatic
    /// start) honors a retained failure that pauses automatic retries;
    /// `presentsKeyScreen` shows the key screen when the run ends needing
    /// the listener's own key.
    func startAnalysis(
        transcript document: EpisodeTranscriptDocument,
        transcriptState: EpisodeTranscriptState? = .completed,
        retryFailed: Bool = true,
        presentsKeyScreen: Bool = true,
        modelContext: ModelContext
    ) {
        guard activeTask == nil else {
            failures.record(EpisodeAdAnalysisError.anotherJobActive, episodeID: document.episodeID)
            return
        }
        guard runEnvironment != nil else {
            failures.record(EpisodeAdAnalysisError.clientDisabled, episodeID: document.episodeID)
            return
        }
        guard transcriptState == .completed else {
            failures.record(EpisodeAdAnalysisError.transcriptNotCompleted, episodeID: document.episodeID)
            return
        }

        failures.clear(episodeID: document.episodeID)
        let runID = UUID()
        activate(episodeID: document.episodeID, runID: runID)
        activeTask = Task {
            await runAnalysis(
                runID: runID,
                transcript: document,
                retryFailed: retryFailed,
                presentsKeyScreen: presentsKeyScreen,
                launchRunRecordID: nil,
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
        try fileStore.writeRunState(.init(transcriptFingerprint: document.transcriptFingerprint), episodeID: document.episodeID)
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
        cancelActiveRun(reason: .listener)
        await activeTask.value
    }

    /// One device run: the replay gate, preparation, the route, the
    /// episode's running record, the run record before the first send, the
    /// pipeline, then the document, and only then the run record's end.
    /// `launchRunRecordID` names the run a launch resumes; such a run never
    /// becomes a new one.
    private func runAnalysis(
        runID: UUID,
        transcript document: EpisodeTranscriptDocument,
        retryFailed: Bool,
        presentsKeyScreen: Bool,
        launchRunRecordID: String?,
        modelContext: ModelContext
    ) async {
        defer {
            deactivate(episodeID: document.episodeID, runID: runID)
        }

        guard !Task.isCancelled, let environment = runEnvironment else {
            return
        }

        var relativePath: String?
        var run: DeviceRun?
        do {
            if !retryFailed, let blocked = try await automaticReplayError(for: document) { throw blocked }
            let declaredDuration = Self.declaredDuration(for: document.episodeID, modelContext: modelContext)
            let preparation = try await prepareAnalysis(transcript: document, declaredDuration: declaredDuration)
            relativePath = preparation.relativePath
            try ensureOwnsActiveRun(episodeID: document.episodeID, runID: runID)

            let resumableRunID: String?
            if let launchRunRecordID {
                // Kept replies are reused only for the same inputs: the
                // validator reads request fields no payload carries.
                let open = environment.runs.record(id: launchRunRecordID)
                guard open?.transcriptFingerprint == preparation.fingerprint,
                      open?.inputDigest == preparation.inputDigest
                else {
                    closeRun(launchRunRecordID, environment: environment, modelContext: modelContext)
                    throw EpisodeAdAnalysisError.runInterrupted
                }
                resumableRunID = launchRunRecordID
            } else {
                resumableRunID = resumableRun(
                    episodeID: document.episodeID,
                    preparation: preparation,
                    runs: environment.runs
                )
            }
            let resolution = await environment.resolveRoute(resumingRunID: resumableRunID)
            try ensureOwnsActiveRun(episodeID: document.episodeID, runID: runID)
            if launchRunRecordID != nil, resolution.resumingRunID == nil {
                throw EpisodeAdAnalysisError.runInterrupted
            }

            try beginEpisodeRecord(document, preparation: preparation, modelContext: modelContext)
            guard let policy = resolution.policy?.adDetection, resolution.keyRequiredReason == nil else {
                throw EpisodeAdAnalysisError.keyRequired(resolution.keyRequiredReason ?? .proxyUnavailable)
            }

            if case .direct(let provider) = resolution.route {
                activeDirectProvider = provider
            }
            let runRecordID: String
            if let resumingRunID = resolution.resumingRunID {
                runRecordID = resumingRunID
            } else {
                closeOpenRuns(episodeID: document.episodeID, environment: environment, modelContext: modelContext)
                runRecordID = UUID().uuidString
            }
            activeProgress = AdAnalysisRunProgress(
                windowCount: AdWindowing.windowCount(
                    segmentCount: preparation.request.segments.count,
                    policy: policy.settings
                ),
                model: policy.model
            )
            let sendLog = AnalysisProviderSendLog()
            let onStep = progressHandler(runID: runID)
            let transport: any AnalysisProviderTransport
            do {
                transport = try environment.makeTransport(
                    for: resolution,
                    runID: runRecordID,
                    observer: AnalysisSendObservers(observers: [
                        sendLog,
                        environment.runs.observer(runID: runRecordID),
                        AdAnalysisRunProgress.SendObserver(onSend: onStep),
                    ]),
                    onReused: { request in onStep(request.purpose, true) }
                )
            } catch {
                throw Self.transportFailure(error)
            }
            if resolution.resumingRunID == nil {
                try environment.runs.begin(AnalysisRunRecord(
                    id: runRecordID,
                    feature: .adDetection,
                    episodeID: document.episodeID,
                    podcastID: document.podcastID,
                    transcriptFingerprint: preparation.fingerprint,
                    inputDigest: preparation.inputDigest,
                    resolution: resolution,
                    policy: .adDetection(policy)
                ))
            }
            run = DeviceRun(id: runRecordID)

            let outcome = await Self.detectAds(
                preparation.request,
                policy: policy,
                transport: transport,
                clock: environment.clock
            )
            run?.outcome = outcome
            if case .failed = outcome {
                run?.listenerFailure = AnalysisProviderFailure.resolve(outcome, sends: sendLog.sends)
            }
            try ensureOwnsActiveRun(episodeID: document.episodeID, runID: runID)
            // The listener's key went away mid-run: the run needs a key again.
            if case .failed(let failure) = outcome, failure.code != .cancelled,
               let removal = environment.keyRemoval(runID: runRecordID) {
                throw EpisodeAdAnalysisError.keyRequired(removal)
            }
            let response = try Self.response(from: outcome, listenerFailure: run?.listenerFailure, policy: policy)

            let coarseDocument = makeDocument(
                transcript: document,
                response: response,
                fingerprint: preparation.fingerprint,
                transcriptSegmentCount: preparation.segments.count
            )
            let analysisDocument = await EpisodeAdBoundaryRefiner.refined(coarseDocument, transcript: document)
            try Task.checkCancellation()
            try ensureOwnsActiveRun(episodeID: document.episodeID, runID: runID)
            try completeAnalysis(
                episodeID: document.episodeID,
                fingerprint: preparation.fingerprint,
                relativePath: preparation.relativePath,
                document: analysisDocument,
                response: response,
                modelContext: modelContext
            )
            failures.clear(episodeID: document.episodeID)
            if let run { endRun(run, environment: environment, modelContext: modelContext) }
        } catch is CancellationError {
            endStoppedRun(run, transcript: document, relativePath: relativePath, runID: runID, environment: environment, modelContext: modelContext)
        } catch {
            guard !Task.isCancelled, ownsActiveRun(episodeID: document.episodeID, runID: runID) else {
                endStoppedRun(run, transcript: document, relativePath: relativePath, runID: runID, environment: environment, modelContext: modelContext)
                return
            }
            if let failure = error as? EpisodeAdAnalysisHTTPError {
                do { try await retainFailure(failure, transcript: document) }
                catch { failures.record(error, episodeID: document.episodeID) }
            }
            guard !Task.isCancelled, ownsActiveRun(episodeID: document.episodeID, runID: runID) else {
                endStoppedRun(run, transcript: document, relativePath: relativePath, runID: runID, environment: environment, modelContext: modelContext)
                return
            }
            markFailed(
                episodeID: document.episodeID,
                relativePath: relativePath,
                error: error,
                modelContext: modelContext
            )
            // A run whose pipeline succeeded but whose document did not
            // install stays open with its replies, so the next start resumes
            // it under the same id and pays nothing again.
            if let run, !run.succeeded {
                endRun(run, environment: environment, modelContext: modelContext)
            }
            followUpFailure(error, presentsKeyScreen: presentsKeyScreen, environment: environment)
        }
    }

    /// One device run in flight: its record id and, once the pipeline
    /// returns, its outcome.
    private struct DeviceRun {
        let id: String
        var outcome: AnalysisOutcome?
        var listenerFailure: AnalysisProviderFailure?

        var succeeded: Bool {
            if case .adDetection = outcome { true } else { false }
        }
    }

    /// The device run a launch resumes.
    private struct DeviceResume {
        let episodeID: String
        let runRecordID: String
    }

    @concurrent
    private static func detectAds(
        _ request: AdAnalysisRequest,
        policy: AdDetectionAnalysisPolicy,
        transport: any AnalysisProviderTransport,
        clock: any AnalysisClock
    ) async -> AnalysisOutcome {
        await AnalysisRunner(transport: transport, clock: clock).detectAds(request, policy: policy)
    }

    /// The run's response as the service would have returned it, or the
    /// error the service would have answered its failure with: the same
    /// body, read the same way, so retained failures and replay suppression
    /// behave as they did for the service.
    private static func response(
        from outcome: AnalysisOutcome,
        listenerFailure: AnalysisProviderFailure?,
        policy: AdDetectionAnalysisPolicy
    ) throws -> EpisodeAdAnalysisAPIResponse {
        switch outcome {
        case .adDetection(let response):
            return try EpisodeAdAnalysisJSONCoding.decoder()
                .decode(EpisodeAdAnalysisAPIResponse.self, from: Data(response.jsonText.utf8))
        case .failed(let failure):
            if failure.code == .cancelled {
                throw CancellationError()
            }
            throw EpisodeAdAnalysisHTTPError(
                statusCode: failure.status,
                body: Data(JSONWriter.string(failure.errorJSON(policyRevision: policy.settings.revision)).utf8),
                listenerFailure: listenerFailure
            )
        case .chaptersSummary:
            throw EpisodeAdAnalysisHTTPError(statusCode: -1, code: "invalid_response", detail: nil)
        }
    }

    private static func transportFailure(_ error: AnalysisTransportFactoryError) -> any Error {
        switch error {
        case .keyRequired(let reason):
            EpisodeAdAnalysisError.keyRequired(reason)
        case .configuration:
            EpisodeAdAnalysisHTTPError(statusCode: -1, code: "provider_configuration", detail: nil)
        }
    }

    /// The open run of the episode on the same inputs that a new start
    /// resumes instead of dispatching again, so the trial counts it once.
    private func resumableRun(
        episodeID: String,
        preparation: EpisodeAdAnalysisPreparation,
        runs: AnalysisRunRecordStore
    ) -> String? {
        guard let run = runs.latestDispatched(feature: .adDetection, episodeID: episodeID),
              run.transcriptFingerprint == preparation.fingerprint,
              run.inputDigest == preparation.inputDigest,
              Date.now.timeIntervalSince(run.startedAt) <= resumeTTL
        else {
            return nil
        }
        return run.id
    }

    /// Closes the episode's open runs a new run replaces, so none of them
    /// resumes later.
    private func closeOpenRuns(
        episodeID: String,
        environment: any EpisodeAdAnalysisRunEnvironment,
        modelContext: ModelContext
    ) {
        for _ in 0..<AnalysisRunRecordStore.maximumRecords {
            guard let open = environment.runs.latestDispatched(feature: .adDetection, episodeID: episodeID) else {
                return
            }
            closeRun(open.id, environment: environment, modelContext: modelContext)
        }
    }

    /// Ends an open run nothing will resume; the tokens it spent still count.
    private func closeRun(_ runID: String, environment: any EpisodeAdAnalysisRunEnvironment, modelContext: ModelContext) {
        recordUsage(ofRunID: runID, environment: environment, modelContext: modelContext)
        environment.runs.markCancelled(runID: runID)
    }

    /// A run killed after its document was installed but before its record
    /// ended: the completed record on the run's transcript proves the
    /// install, so the run finishes and its usage counts (once, by run id).
    private func finishInstalledRuns(modelContext: ModelContext) {
        guard let environment = runEnvironment else {
            return
        }
        for record in recordSet.records where record.state == .completed && record.failureKind == nil {
            guard let open = environment.runs.latestDispatched(feature: .adDetection, episodeID: record.episodeID),
                  open.transcriptFingerprint == record.transcriptFingerprint
            else {
                continue
            }
            recordUsage(ofRunID: open.id, environment: environment, modelContext: modelContext)
            environment.runs.finishInstalled(runID: open.id)
        }
    }

    /// Ends the run record after the episode's document (or failure) is in
    /// place. Usage is counted first: a kill between the two counts the run
    /// again at worst (once, by run id), never not at all.
    private func endRun(_ run: DeviceRun, environment: any EpisodeAdAnalysisRunEnvironment, modelContext: ModelContext) {
        guard let outcome = run.outcome else {
            closeRun(run.id, environment: environment, modelContext: modelContext)
            return
        }
        recordUsage(of: run, environment: environment, modelContext: modelContext)
        environment.runs.finish(
            runID: run.id,
            outcome: outcome,
            listenerFailure: run.listenerFailure,
            background: environment.holdsContinuedProcessingCard
        )
    }

    /// A run stopped before its end. One whose key the listener removed in
    /// AI Services ends as a send that found the key gone ends it: the
    /// episode's record fails as needing a key, so its card and queue row
    /// say so at once, and no key screen opens (the listener is where keys
    /// are added). Any other stop leaves the episode's record for the next
    /// start or launch.
    private func endStoppedRun(
        _ run: DeviceRun?,
        transcript document: EpisodeTranscriptDocument,
        relativePath: String?,
        runID: UUID,
        environment: any EpisodeAdAnalysisRunEnvironment,
        modelContext: ModelContext
    ) {
        if activeCancelReason == .keyRemoved, ownsActiveRun(episodeID: document.episodeID, runID: runID) {
            keyRemovedEpisodeIDs.insert(document.episodeID)
            markFailed(
                episodeID: document.episodeID,
                relativePath: relativePath,
                error: EpisodeAdAnalysisError.keyRequired(.noKey),
                modelContext: modelContext
            )
        }
        if let run { endCancelledRun(run, environment: environment, modelContext: modelContext) }
    }

    /// A run the listener stopped ends cancelled (its tokens still count);
    /// one whose card expired keeps its replies, so the next start of the
    /// episode or the next launch resumes it; one whose key the listener
    /// removed fails as needing a key, its usage counted first.
    private func endCancelledRun(_ run: DeviceRun, environment: any EpisodeAdAnalysisRunEnvironment, modelContext: ModelContext) {
        switch activeCancelReason {
        case .expiration:
            environment.runs.markExpired(runID: run.id)
        case .keyRemoved:
            recordUsage(of: run, environment: environment, modelContext: modelContext)
            environment.runs.finish(
                runID: run.id,
                outcome: .failed(Self.keyRemovedFailure),
                listenerFailure: .keyRequired,
                background: environment.holdsContinuedProcessingCard
            )
        case .listener, nil:
            closeRun(run.id, environment: environment, modelContext: modelContext)
        }
    }

    /// The pipeline's failure when a send finds the run's key gone, so a
    /// run stopped for an in-app removal keeps the same record.
    private static let keyRemovedFailure = AnalysisFailure(feature: .adDetection, code: .providerRejected, status: 503)

    private func recordUsage(of run: DeviceRun, environment: any EpisodeAdAnalysisRunEnvironment, modelContext: ModelContext) {
        recordUsage(ofRunID: run.id, environment: environment, modelContext: modelContext)
    }

    /// Counts a run on the listener's key from its record's totals, before
    /// the record's terminal state is written; the usage store adds only
    /// the totals' growth under the run id. The record says whether its
    /// usage is saved, so a failed save is counted at the next launch.
    private func recordUsage(ofRunID runID: String, environment: any EpisodeAdAnalysisRunEnvironment, modelContext: ModelContext) {
        guard let record = environment.runs.record(id: runID),
              record.route == .direct,
              record.inputTokens > 0 || record.outputTokens > 0
        else {
            return
        }
        let saved = environment.recordUsage(
            provider: record.provider,
            inputTokens: Int(clamping: record.inputTokens),
            outputTokens: Int(clamping: record.outputTokens),
            runID: runID,
            modelContext: modelContext
        )
        if saved {
            environment.runs.markUsageRecorded(runID: runID)
        } else if record.usageRecorded == true {
            // Counted before, but this growth was not saved.
            environment.runs.update(runID: runID) { $0.usageRecorded = false }
        }
    }

    /// Ended direct runs whose usage never saved (the save failed, or the
    /// process stopped first) are counted at launch, once by run id.
    private func recordUnaccountedUsage(modelContext: ModelContext) {
        guard let environment = runEnvironment else {
            return
        }
        for run in environment.runs.unaccountedDirectRuns(feature: .adDetection) {
            recordUsage(ofRunID: run.id, environment: environment, modelContext: modelContext)
        }
    }

    /// After a failed run: the trial status is read again when the trial
    /// refused the run for its allowance, and the key screen opens for a
    /// run that needs the listener's key when the start asked for it.
    private func followUpFailure(
        _ error: any Error,
        presentsKeyScreen: Bool,
        environment: any EpisodeAdAnalysisRunEnvironment
    ) {
        if let listener = (error as? EpisodeAdAnalysisHTTPError)?.listenerFailure,
           listener == .trialExhausted || listener == .trialPaused {
            environment.refreshTrialStatus()
        }
        if presentsKeyScreen, let reason = Self.failureKind(for: error).keyRequiredReason {
            environment.presentKeyRequired(reason)
        }
    }

    /// Steps reported from the transport's threads hop to the main actor
    /// and count only for the run that is still active.
    private func progressHandler(runID: UUID) -> @Sendable (AnalysisProviderRequest.Purpose, Bool) -> Void {
        { [weak self] purpose, answered in
            Task { @MainActor [weak self] in
                self?.noteProgress(purpose, answered: answered, runID: runID)
            }
        }
    }

    private func noteProgress(_ purpose: AnalysisProviderRequest.Purpose, answered: Bool, runID: UUID) {
        guard activeRunID == runID else {
            return
        }
        activeProgress?.note(purpose, answered: answered)
    }

    /// The episode's record turns running for this run, and the run state
    /// keeps the last completed document to restore if the run fails.
    private func beginEpisodeRecord(
        _ document: EpisodeTranscriptDocument,
        preparation: EpisodeAdAnalysisPreparation,
        modelContext: ModelContext
    ) throws {
        let previous = record(for: document.episodeID).flatMap { $0.state == .completed ? $0.analysisRelativePath : nil }
            ?? (try? fileStore.readRunState(episodeID: document.episodeID))?.previousAnalysisPath
        try fileStore.writeRunState(.init(transcriptFingerprint: preparation.fingerprint, previousAnalysisPath: previous), episodeID: document.episodeID)
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
    }

    private func activate(episodeID: String, runID: UUID) {
        activeEpisodeID = episodeID
        activeRunID = runID
        activeCancelReason = nil
        activeDirectProvider = nil
        activeProgress = nil
        keyRemovedEpisodeIDs.remove(episodeID)
    }

    private func deactivate(episodeID: String, runID: UUID) {
        guard ownsActiveRun(episodeID: episodeID, runID: runID) else {
            return
        }
        activeTask = nil
        activeEpisodeID = nil
        activeRunID = nil
        activeCancelReason = nil
        activeDirectProvider = nil
        activeProgress = nil
        failures.stateChanges.notify()
    }

    private func ensureOwnsActiveRun(episodeID: String, runID: UUID) throws {
        try Task.checkCancellation()
        guard ownsActiveRun(episodeID: episodeID, runID: runID) else {
            throw CancellationError()
        }
    }

    /// The feed's declared runtime for the episode, when the cache has one.
    /// Dynamic ad insertion serves files longer than this; the pipeline
    /// counts the excess toward the episode ad budget instead of failing the
    /// analysis closed on ad-heavy inventory.
    private static func declaredDuration(for episodeID: String, modelContext: ModelContext) -> TimeInterval? {
        let descriptor = FetchDescriptor<EpisodeCacheRecord>(predicate: #Predicate { $0.episodeID == episodeID })
        guard let duration = try? modelContext.fetch(descriptor).first?.duration,
              duration.isFinite, duration > 0
        else { return nil }
        return duration
    }

    @concurrent
    private func prepareAnalysis(
        transcript document: EpisodeTranscriptDocument,
        declaredDuration: TimeInterval? = nil
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
        let input = try Self.pipelineInput(Self.makeRequest(
            transcript: document,
            segments: segments,
            fingerprint: fingerprint,
            requestID: UUID().uuidString,
            declaredDuration: declaredDuration
        ))
        SoundLabResponsivenessDiagnostics.mark(
            "analysis-normalize-fingerprint-end",
            episodeID: document.episodeID
        )
        try Task.checkCancellation()

        return EpisodeAdAnalysisPreparation(
            segments: segments,
            fingerprint: fingerprint,
            relativePath: relativePath,
            request: input.request,
            inputDigest: input.digest
        )
    }

    /// The service's request JSON, written with the app's coding and read
    /// by the device pipeline exactly as the service read it, and the
    /// digest of everything in it the run depends on: the lowercase hex
    /// SHA-256 of its sorted-key JSON without `request_id` and
    /// `retry_failed`. The validator reads fields (the declared runtime, the
    /// audio duration) that no provider payload carries, so a resume reuses
    /// kept replies only under the same digest.
    private nonisolated static func pipelineInput(
        _ request: EpisodeAdAnalysisAPIRequest
    ) throws -> (request: AdAnalysisRequest, digest: String) {
        let data = try EpisodeAdAnalysisJSONCoding.encoder().encode(request)
        let json = try JSONParser.parse(String(decoding: data, as: UTF8.self))
        let identity = json.objectMembers
            .map { JSONValue.object($0.filter { $0.key != "request_id" && $0.key != "retry_failed" }) } ?? json
        let digest = SHA256.hash(data: Data(JSONWriter.string(identity.sortedKeys()).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return (try AdAnalysisRequest(json: json), digest)
    }

    private func startResumingDeviceRun(_ resume: DeviceResume, modelContext: ModelContext) {
        guard activeTask == nil else {
            return
        }

        let runID = UUID()
        activate(episodeID: resume.episodeID, runID: runID)
        activeTask = Task {
            await runResumedDeviceAnalysis(runID: runID, resume: resume, modelContext: modelContext)
        }
        failures.stateChanges.notify()
    }

    private func runResumedDeviceAnalysis(runID: UUID, resume: DeviceResume, modelContext: ModelContext) async {
        guard let transcript = await storedTranscript(episodeID: resume.episodeID, modelContext: modelContext) else {
            if ownsActiveRun(episodeID: resume.episodeID, runID: runID), !Task.isCancelled {
                markFailed(
                    episodeID: resume.episodeID,
                    relativePath: nil,
                    error: EpisodeAdAnalysisError.runInterrupted,
                    modelContext: modelContext
                )
            }
            deactivate(episodeID: resume.episodeID, runID: runID)
            return
        }
        await runAnalysis(
            runID: runID,
            transcript: transcript,
            retryFailed: true,
            presentsKeyScreen: false,
            launchRunRecordID: resume.runRecordID,
            modelContext: modelContext
        )
    }

    private func storedTranscript(episodeID: String, modelContext: ModelContext) async -> EpisodeTranscriptDocument? {
        let descriptor = FetchDescriptor<EpisodeTranscriptRecord>(predicate: #Predicate { $0.episodeID == episodeID })
        guard let path = (try? modelContext.fetch(descriptor))?.first?.transcriptRelativePath else {
            return nil
        }
        return try? await EpisodeTranscriptFileStore(baseDirectory: fileStore.baseDirectory).readOffCaller(relativePath: path)
    }

    private func startResumingAnalysis(
        _ context: AnalysisResumeContext,
        modelContext: ModelContext
    ) {
        guard activeTask == nil else {
            return
        }

        let runID = UUID()
        activate(episodeID: context.episodeID, runID: runID)
        activeTask = Task {
            await runResumedAnalysis(
                runID: runID,
                context: context,
                modelContext: modelContext
            )
        }
    }

    /// Polls a job an earlier build started until it completes. A lost job
    /// fails as interrupted; nothing is resubmitted.
    private func runResumedAnalysis(
        runID: UUID,
        context: AnalysisResumeContext,
        modelContext: ModelContext
    ) async {
        defer {
            deactivate(episodeID: context.episodeID, runID: runID)
        }

        let resumedTranscript = await storedTranscript(episodeID: context.episodeID, modelContext: modelContext)
        do {
            let state = try fileStore.readRunState(episodeID: context.episodeID)
            let jobID = state.flatMap { $0.transcriptFingerprint == context.transcriptFingerprint ? $0.jobID : nil }
                ?? context.transcriptFingerprint
            let response = try await pollUntilCompleted(
                jobID: jobID,
                initialPollAfter: resumeInitialPollAfter
            )
            try ensureOwnsActiveRun(episodeID: context.episodeID, runID: runID)

            var document = makeDocument(
                episodeID: context.episodeID,
                podcastID: context.podcastID,
                transcriptUpdatedAt: context.transcriptUpdatedAt,
                response: response,
                fingerprint: context.transcriptFingerprint,
                transcriptSegmentCount: context.transcriptSegmentCount
            )
            if let transcript = resumedTranscript,
               await isCurrentAnalysisDocumentOffCaller(document, for: transcript) {
                document = await EpisodeAdBoundaryRefiner.refined(document, transcript: transcript)
            }
            try ensureOwnsActiveRun(episodeID: context.episodeID, runID: runID)
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
            guard ownsActiveRun(episodeID: context.episodeID, runID: runID) else { return }
            if let failure = error as? EpisodeAdAnalysisHTTPError, let transcript = resumedTranscript {
                do { try await retainFailure(failure, transcript: transcript) }
                catch { failures.record(error, episodeID: context.episodeID) }
            }
            guard !Task.isCancelled, ownsActiveRun(episodeID: context.episodeID, runID: runID) else { return }
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
    ) async throws -> EpisodeAdAnalysisAPIResponse {
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
    ) -> AnalysisJobPoller<EpisodeAdAnalysisAPIResponse> {
        AnalysisJobPoller(
            timeout: timeout,
            sleep: sleep,
            isTransientJobFailure: { ($0 as? EpisodeAdAnalysisHTTPError)?.isTransientJobFailure == true },
            isTransientPollFailure: { ($0 as? EpisodeAdAnalysisHTTPError)?.isTransientPollFailure == true },
            timedOutError: EpisodeAdAnalysisError.analysisTimedOut,
            jobIDMismatchError: jobIDMismatchError(),
            jobIDsMatch: EpisodeAdAnalysisJobHandle.sameInput
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
        try fileStore.writeRunState(.init(transcriptFingerprint: fingerprint), episodeID: episodeID)
    }

    private static func jobIDMismatchError() -> EpisodeAdAnalysisHTTPError {
        EpisodeAdAnalysisHTTPError(statusCode: -1, code: "job_id_mismatch", detail: nil)
    }

    private nonisolated static func makeRequest(
        transcript document: EpisodeTranscriptDocument,
        segments: [OpenCastTranscriptSegment],
        fingerprint: String,
        requestID: String,
        declaredDuration: TimeInterval?
    ) -> EpisodeAdAnalysisAPIRequest {
        EpisodeAdAnalysisAPIRequest(
            schemaVersion: EpisodeAdAnalysisContract.schemaVersion,
            requestID: requestID,
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            episodeTitle: nil,
            podcastTitle: nil,
            transcript: EpisodeAdAnalysisAPITranscriptMetadata(
                languageCode: document.languageCode,
                audioDuration: document.audioDuration,
                declaredDuration: declaredDuration,
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
                    evidenceQuote: span.evidenceQuote,
                    startBoundary: span.startBoundary,
                    endBoundary: span.endBoundary
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
            updatedAt: .now,
            policyRevision: response.policyRevision
        )
    }

    private func isUsableCurrentRecord(
        _ record: EpisodeAdAnalysisRecord,
        for document: EpisodeTranscriptDocument,
        transcriptFingerprint: String,
        transcriptSegmentCount: Int
    ) -> Bool {
        // Only explicitly supported whole-break policies may render or skip,
        // even when an older cue-fragment policy's transcript still matches.
        // Whole-second comparison: the transcript's `updatedAt` loses its
        // fractional seconds on the `.iso8601` disk round trip, while the
        // SwiftData record keeps full precision, so exact equality would
        // brand a record seeded from an in-memory document permanently stale.
        return (record.state != .completed || EpisodeAdAnalysisContract.supports(policy: record.policy))
            && record.transcriptFingerprint == transcriptFingerprint
            && record.transcriptUpdatedAt.truncatedToWholeSeconds == document.updatedAt.truncatedToWholeSeconds
            && record.transcriptSegmentCount == transcriptSegmentCount
            && record.transcriptState == .completed
            // A failed first attempt has no output document. Its error still
            // belongs to these transcript inputs and must remain retryable.
            && (record.state != .completed || fileStore.documentExists(relativePath: record.analysisRelativePath))
    }

    private nonisolated static func isCurrentAnalysisDocument(
        _ analysisDocument: EpisodeAdAnalysisDocument,
        for transcriptDocument: EpisodeTranscriptDocument,
        transcriptFingerprint: String,
        transcriptSegmentCount: Int
    ) -> Bool {
        EpisodeAdAnalysisContract.supports(policy: analysisDocument.policy)
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
            if let state = try fileStore.readRunState(episodeID: episodeID),
               let path = state.previousAnalysisPath,
               let previous = try? fileStore.read(relativePath: path) {
                try importCompletedAnalysis(previous, modelContext: modelContext)
                try fileStore.writeRunState(state, episodeID: episodeID)
                if let record = record(for: episodeID) {
                    record.failureKind = Self.failureKind(for: error)
                    record.errorMessage = error.localizedDescription
                    try commit(episodeID: episodeID, modelContext: modelContext, resort: true)
                }
                failures.record(error, episodeID: episodeID)
                return
            }
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

    /// Server codes whose typed transient failure means time ran out rather
    /// than the service being unreachable.
    private static let timedOutCodes: Set<String> = [
        "gemini_timeout",
        "analysis_deadline_exhausted",
        "execution_expired"
    ]

    /// A device run's listener failure first, then the service's typed
    /// category, then code, then error type; the card's copy follows the
    /// kind, while `errorMessage` keeps the code for Diagnostics.
    private static func failureKind(for error: Error) -> EpisodeAnalysisFailureKind {
        if let analysisError = error as? EpisodeAdAnalysisError {
            switch analysisError {
            case .keyRequired(let reason):
                return EpisodeAnalysisFailureKind(keyRequired: reason)
            case .analysisTimedOut:
                return .timedOut
            case .runInterrupted:
                return .interrupted
            case .clientDisabled, .appAttestUnavailable, .transcriptNotCompleted, .analysisDocumentMissing,
                 .anotherJobActive, .unrecognizedSpanKind:
                return .generic
            }
        }
        if let httpError = error as? EpisodeAdAnalysisHTTPError {
            if let listener = httpError.listenerFailure {
                return failureKind(for: listener, replayFailure: httpError.replayFailure)
            }
            if httpError.isCapExceeded {
                return .capExceeded
            }
            switch httpError.replayFailure?.category {
            case .capacity:
                return .capExceeded
            case .transientTransport:
                return timedOutCodes.contains(httpError.code) ? .timedOut : .serviceUnavailable
            case .interruptedJob:
                return .interrupted
            case .validationExhausted:
                return .validationExhausted
            case .unsupportedInput:
                return .generic
            case nil:
                if httpError.isTransientJobFailure {
                    return .interrupted
                }
                return httpError.isTransientPollFailure ? .serviceUnavailable : .generic
            }
        }
        if error is URLError {
            return .serviceUnavailable
        }
        return .generic
    }

    /// What a device run's failure tells the listener, as the card's kind.
    private static func failureKind(
        for listener: AnalysisProviderFailure,
        replayFailure: OpenCastAdAnalysisFailure?
    ) -> EpisodeAnalysisFailureKind {
        switch listener {
        case .invalidKey, .billingOrQuota:
            .providerRejectedKey
        case .rateLimited, .dailyLimit, .overloaded:
            .providerLimited
        case .modelUnavailable, .unreachable:
            .providerUnavailable
        case .timeout:
            .timedOut
        case .malformedAnswer:
            replayFailure?.category == .validationExhausted ? .validationExhausted : .generic
        case .requestRejected:
            .generic
        case .trialExhausted:
            .keyRequiredTrialExhausted
        case .trialRunBound:
            .keyRequiredTrialRunBound
        case .trialPaused:
            .keyRequiredTrialPaused
        case .trialUnavailable:
            .keyRequiredProxyUnavailable
        case .keyRequired:
            .keyRequiredNoKey
        }
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
            resumeTTL: resumeTTL,
            interruptedFailureKind: .interrupted
        )
    }

    /// Reconciles the stored records. The reconciler gives one resume slot
    /// to the first running record that can use it: a job an earlier build
    /// started, or a device run whose run record is still open on the same
    /// transcript and younger than `resumeTTL`. Every other running record
    /// fails as interrupted.
    private func reconcile(modelContext: ModelContext) throws -> (job: AnalysisResumeContext?, device: DeviceResume?) {
        var device: DeviceResume?
        var reconciler = reconciler
        if let runs = runEnvironment?.runs {
            let resumeTTL = resumeTTL
            reconciler.resumesDeviceRun = { record, now in
                guard device == nil,
                      AnalysisResumeContext(record: record) != nil,
                      let run = runs.latestDispatched(feature: .adDetection, episodeID: record.episodeID),
                      run.transcriptFingerprint == record.transcriptFingerprint,
                      now.timeIntervalSince(run.startedAt) <= resumeTTL
                else {
                    return false
                }
                device = DeviceResume(episodeID: record.episodeID, runRecordID: run.id)
                return true
            }
        }
        let outcome = try reconciler.reconcile(
            recordSet.fetchRecords(modelContext: modelContext),
            modelContext: modelContext
        )
        duplicateRepairCount += outcome.repairedGroupCount
        return (outcome.resumeContext, outcome.resumeContext == nil ? device : nil)
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
