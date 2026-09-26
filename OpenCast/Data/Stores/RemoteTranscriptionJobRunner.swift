import DeviceCheck
import Foundation
import OpenCastTranscription
import SwiftData

/// Runs exactly one remote transcription job end to end: bootstrap →
/// create/attach (purpose-keyed idempotency) while the explicit episode
/// download starts/reuses → report exact local source identity → poll with
/// the server's pacing plus jitter → drive the exact-device upload when (and
/// only when) the server requests it → fetch/validate result → durable local
/// import → ack → refresh balance. Progress surfaces through
/// `RemoteTranscriptionJobEvent`; failures through
/// `RemoteTranscriptionJobRunError`.
///
/// The persisted reference is the client half of the server's
/// `(account, clientRequestID)` idempotency contract: it is marked
/// `createAttempted` before a create can leave the process, attached as soon
/// as the response lands, kept (with a recoverable exit) on every transport
/// or local failure afterwards, and cleared only from terminal paths. No
/// error or task cancellation ever sends `/cancel`; only `cancelServerJob`,
/// called from user-cancel paths, does, and concurrent calls for one
/// reference share a single resolution. A cancellation that lands after the
/// durable import completes the run instead of parking it: the transcript is
/// already saved, so there is nothing left to stop. The one documented
/// exception to the cancel rule is a detect run observing `awaiting_credits`,
/// an unfunded reservation the runner releases before any charge.
final class RemoteTranscriptionJobRunner {
    typealias UploadSessionFactory = (_ jobID: String, _ sourceFileURL: URL) -> RemoteTranscriptionUploadSession

    /// Extra create-request context for a detect-ads job: the server chains
    /// ad detection after stitching under this podcast identity.
    struct AdAnalysisContext {
        let podcastID: String
        let episodeTitle: String?
        let podcastTitle: String?
    }

    /// How a user-authorized cancel resolved against the server.
    enum UserCancelResolution: Equatable {
        /// One `/cancel` reached the server (any landed answer counts); the
        /// reference is cleared.
        case cancelled(jobID: String)
        /// No create ever left the process, so there is nothing to cancel;
        /// the reference is cleared without a `/cancel`.
        case noServerJob
        /// The job could not be resolved or the cancel response was lost.
        /// The persisted intent stays so the next recovery trigger retries
        /// it; polling never re-attaches meanwhile.
        case uncertain
    }

    /// Grace for transient backend loss (≈2¼ minutes total): long enough to
    /// ride out a Wi-Fi handoff mid-poll, short enough that a genuinely dead
    /// backend still parks the run promptly.
    static let defaultTransportRetryDelays: [Duration] = [
        .seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60),
    ]

    /// Local legs (App Attest, keychain, decode) either recover at once or
    /// not at all, so their ladder is short.
    static let defaultLocalRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    private let api: any RemoteTranscriptionAPI
    private let downloads: DownloadStore
    private let transcriptions: EpisodeTranscriptionStore
    private let store: RemoteTranscriptionJobStore
    private let makeUploadSession: UploadSessionFactory
    private let transportRetryDelays: [Duration]
    private let localRetryDelays: [Duration]
    private let progressTracker = RemoteTranscriptionProgressTracker()
    /// Create requests this process has sent, keyed by reference, so a user
    /// cancel of a `createAttempted` reference can replay the same request
    /// to learn its job id.
    private var createRequests: [ReferenceKey: OpenCastRemoteTranscriptionJobCreateRequest] = [:]
    /// User cancels in flight, keyed by reference, so a repeated tap or a
    /// recovery trigger racing a tap joins the resolution already underway
    /// instead of sending a second `/cancel`.
    private var userCancels: [ReferenceKey: Task<UserCancelResolution, Never>] = [:]

    private struct ReferenceKey: Hashable {
        let episodeID: String
        let purpose: RemoteTranscriptionJobPurpose
    }

    /// Where a run is when a leg fails, which decides the exit disposition.
    /// A re-run starts at the stage its persisted reference already reached,
    /// so a failure ahead of the create leg (bootstrap) is judged against the
    /// job that may already exist, never as "no attempt was made".
    private enum RunStage {
        /// Before `createAttempted` was persisted: no server job can exist.
        case beforeCreate
        /// Between marking the attempt and persisting the response, or a
        /// re-run of a `createAttempted` reference whose response was lost.
        case creating
        /// The job id is known; failures only ever change `lastExit`.
        case attached

        init(resuming reference: RemoteTranscriptionJobReference) {
            self = switch reference.createState {
            case .prepared: .beforeCreate
            case .createAttempted: .creating
            case .attached: .attached
            }
        }
    }

    private enum RetryClass {
        case transport
        case local
        case none
    }

    /// The opaque identifiers every diagnostic event of one run carries.
    private struct RunTrail {
        let episodeID: String
        let clientRequestID: String
        let purpose: RemoteTranscriptionJobPurpose
        var jobID: String?
    }

    init(
        api: any RemoteTranscriptionAPI,
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        store: RemoteTranscriptionJobStore,
        uploadSessionFactory: UploadSessionFactory? = nil,
        transportRetryDelays: [Duration] = RemoteTranscriptionJobRunner.defaultTransportRetryDelays,
        localRetryDelays: [Duration] = RemoteTranscriptionJobRunner.defaultLocalRetryDelays
    ) {
        self.api = api
        self.downloads = downloads
        self.transcriptions = transcriptions
        self.store = store
        self.transportRetryDelays = transportRetryDelays
        self.localRetryDelays = localRetryDelays
        makeUploadSession = uploadSessionFactory ?? { jobID, sourceFileURL in
            RemoteTranscriptionUploadSession(
                jobID: jobID,
                sourceFileURL: sourceFileURL,
                api: api,
                transport: BackgroundRemoteTranscriptionUploadTransport(jobID: jobID)
            )
        }
    }

    func run(
        episode: EpisodeListItemSnapshot,
        enclosureURL: String,
        purpose: RemoteTranscriptionJobPurpose = .transcription,
        adAnalysis: AdAnalysisContext? = nil,
        modelContext: ModelContext,
        onEvent: @escaping (RemoteTranscriptionJobEvent) -> Void
    ) async throws -> RemoteTranscriptionJobRunOutcome {
        let episodeID = episode.episodeID
        let key = ReferenceKey(episodeID: episodeID, purpose: purpose)
        let reference = store.reference(for: episodeID, purpose: purpose)
        guard reference.userCancelRequestedAt == nil else {
            // A persisted user intent is never re-attached; only the
            // user-cancel path resolves it.
            throw CancellationError()
        }
        let isFirstAttempt = reference.createState == .prepared
        var trail = RunTrail(
            episodeID: episodeID,
            clientRequestID: reference.clientRequestID,
            purpose: purpose,
            jobID: reference.jobID
        )
        var stage = RunStage(resuming: reference)
        let runStart = ContinuousClock.now
        emit(trail, .runStarted)
        defer {
            if let jobID = trail.jobID {
                progressTracker.remove(jobID: jobID)
            }
        }
        do {
            let bootstrap = try await performLeg(.bootstrap, trail) { try await api.bootstrap() }
            store.updateAccount(bootstrap)

            onEvent(.downloading)
            let request = createRequest(
                episode: episode,
                enclosureURL: enclosureURL,
                clientRequestID: reference.clientRequestID,
                adAnalysis: adAnalysis
            )
            createRequests[key] = request
            // A cancel that lands before this point never marks an attempt,
            // so the prepared reference clears without a server call.
            try Task.checkCancellation()
            store.markCreateAttempted(episodeID: episodeID, purpose: purpose)
            if stage == .beforeCreate {
                stage = .creating
            }
            let created = try await performLeg(.create, trail) { try await api.createJob(request) }
            let jobID = created.job.jobID
            trail.jobID = jobID
            store.attachJob(id: jobID, episodeID: episodeID, purpose: purpose)
            stage = .attached
            // The response is persisted before a cancel that arrived during
            // the create is honored, so the user-cancel path finds the job.
            try Task.checkCancellation()

            // The explicit local download runs concurrently with the server's
            // origin fetch; policy stays foreground/local-only.
            let localFileURL = try await completedDownloadFileURL(
                episode: episode,
                modelContext: modelContext
            )
            onEvent(.verifying)
            let identity = try await localSourceIdentity(
                episode: episode,
                localFileURL: localFileURL
            )
            _ = try await performLeg(.source, trail) {
                try await api.reportSource(jobID: jobID, identity: identity)
            }

            var lastProgress: RemoteTranscriptionActiveProgress?
            var finalStatus = try await pollUntilResult(
                trail: trail,
                waitsForCredits: purpose == .transcription,
                lastProgress: &lastProgress,
                onEvent: onEvent
            )
            if finalStatus.state == .exactUploadRequired || finalStatus.state == .exactUploading {
                // The server could not stage or prove the origin bytes; the
                // user already asked for this transcript, so the exact-copy
                // upload engages without a second confirmation.
                try await uploadExactCopy(
                    jobID: jobID,
                    localFileURL: localFileURL,
                    onEvent: onEvent
                )
                finalStatus = try await pollUntilResult(
                    trail: trail,
                    waitsForCredits: purpose == .transcription,
                    lastProgress: &lastProgress,
                    onEvent: onEvent
                )
            }
            if finalStatus.state == .awaitingCredits {
                // Detect-only exception (D16): a detect pass never parks on
                // credits, which would block the whole queue for the
                // server's awaiting-credits deadline. The reservation is
                // unfunded, so releasing it is a server-state bail before
                // any charge, not an error cancellation.
                try await releaseUnfundedReservation(trail: trail)
            }
            if finalStatus.state == .acknowledged {
                return try reconcileAcknowledged(trail: trail)
            }
            if let failure = terminalFailure(for: finalStatus) {
                store.clearReference(for: episodeID, purpose: purpose)
                throw failure
            }

            onEvent(.processing(finalizingProgress(after: lastProgress)))
            let resultResponse = try await performLeg(.result, trail) {
                try await api.result(jobID: jobID)
            }

            onEvent(.saving)
            let document = try EpisodeRemoteTranscriptMapper.document(
                from: resultResponse.result,
                context: EpisodeRemoteTranscriptMapper.Context(
                    episodeID: episodeID,
                    podcastID: episode.podcastID,
                    sourceAudioURL: enclosureURL,
                    localIdentity: identity,
                    jobProvenanceToken: jobID
                )
            )
            try await transcriptions.importRemoteTranscript(document, modelContext: modelContext)
            emit(trail, .imported, leg: .importTranscript)

            // Ack only after the durable local import; an ack failure is the
            // server's recovery problem (result TTL), never a user failure.
            // The run is committed from here: a local cancellation that lands
            // this late has nothing left to stop (the transcript is saved),
            // so it is recorded on the ack leg and the run still completes
            // without any `/cancel`.
            do {
                _ = try await api.ack(
                    jobID: jobID,
                    normalizedTranscriptSHA256: document.normalizedTranscriptSHA256
                )
                emit(trail, .acknowledged, leg: .ack)
            } catch {
                let ackError: any Error = Task.isCancelled ? CancellationError() : error
                emit(trail, .legFailed, leg: .ack, error: ackError)
            }
            createRequests[key] = nil
            store.clearReference(for: episodeID, purpose: purpose)
            if let refreshed = try? await api.bootstrap() {
                store.updateAccount(refreshed)
            }
            emit(trail, .runEnded, since: runStart, disposition: .cleared)
            return RemoteTranscriptionJobRunOutcome(
                jobID: jobID,
                document: document,
                adAnalysis: resultResponse.adAnalysis
            )
        } catch is CancellationError {
            // Local cancellation is a park or a user cancel; neither is the
            // runner's decision, and the reference stays as it is.
            emit(trail, .runEnded, since: runStart, error: CancellationError(), disposition: .retained)
            throw CancellationError()
        } catch let error as RemoteTranscriptionJobRunError {
            if error == .downloadFailed {
                store.recordExit(.downloadFailed, episodeID: episodeID, purpose: purpose)
            }
            emit(trail, .runEnded, since: runStart, error: error)
            throw error
        } catch is EpisodeRemoteTranscriptMapper.ValidationError {
            emit(trail, .runEnded, since: runStart, error: RemoteTranscriptionJobRunError.resultInvalid)
            throw RemoteTranscriptionJobRunError.resultInvalid
        } catch {
            if Task.isCancelled {
                emit(trail, .runEnded, since: runStart, error: CancellationError(), disposition: .retained)
                throw CancellationError()
            }
            let mapped = exitDisposition(
                for: error,
                stage: stage,
                isFirstAttempt: isFirstAttempt,
                trail: trail
            )
            emit(trail, .runEnded, since: runStart, error: mapped)
            throw mapped
        }
    }

    /// The user-authorized cancel for a reference: persists the intent,
    /// resolves the job id (letting a lost create response replay the same
    /// client request ID), sends at most one `/cancel`, and clears the
    /// reference only after that attempt is recorded. Never called from an
    /// error or task-cancellation path. Concurrent calls for the same
    /// reference await the resolution already in flight.
    func cancelServerJob(
        episodeID: String,
        purpose: RemoteTranscriptionJobPurpose
    ) async -> UserCancelResolution {
        let key = ReferenceKey(episodeID: episodeID, purpose: purpose)
        if let inFlight = userCancels[key] {
            return await inFlight.value
        }
        let resolution = Task {
            defer { self.userCancels[key] = nil }
            return await self.resolveUserCancel(key: key)
        }
        userCancels[key] = resolution
        return await resolution.value
    }

    private func resolveUserCancel(key: ReferenceKey) async -> UserCancelResolution {
        let episodeID = key.episodeID
        let purpose = key.purpose
        guard let reference = store.existingReference(for: episodeID, purpose: purpose) else {
            return .noServerJob
        }
        store.recordUserCancelIntent(episodeID: episodeID, purpose: purpose)
        var trail = RunTrail(
            episodeID: episodeID,
            clientRequestID: reference.clientRequestID,
            purpose: purpose,
            jobID: reference.jobID
        )
        if trail.jobID == nil, reference.createState == .createAttempted {
            // The create response was lost. Replaying the same client
            // request ID attaches the existing job or creates one that is
            // cancelled before funding; it never mints a second request ID.
            guard let request = createRequests[key] else {
                emit(trail, .cancelUncertain, leg: .create, disposition: .retained)
                return .uncertain
            }
            do {
                let created = try await performLeg(.create, trail) { try await api.createJob(request) }
                trail.jobID = created.job.jobID
                store.attachJob(id: created.job.jobID, episodeID: episodeID, purpose: purpose)
            } catch {
                emit(trail, .cancelUncertain, leg: .create, error: error, disposition: .retained)
                return .uncertain
            }
        }
        guard let jobID = trail.jobID else {
            // Prepared: no create ever left the process.
            createRequests[key] = nil
            store.clearReference(for: episodeID, purpose: purpose)
            return .noServerJob
        }
        do {
            _ = try await api.cancel(jobID: jobID)
            emit(trail, .cancelAttempted, leg: .cancel, httpStatus: 200, disposition: .cancelAttempted)
        } catch let error as RemoteTranscriptionHTTPError where error.statusCode > 0 {
            // The server answered, so the one cancel is accounted for even
            // when it refused (the job is already terminal or unknown).
            emit(trail, .cancelAttempted, leg: .cancel, error: error, disposition: .cancelAttempted)
        } catch {
            emit(trail, .cancelUncertain, leg: .cancel, error: error, disposition: .retained)
            return .uncertain
        }
        createRequests[key] = nil
        store.clearReference(for: episodeID, purpose: purpose)
        return .cancelled(jobID: jobID)
    }

    // MARK: Legs

    private func createRequest(
        episode: EpisodeListItemSnapshot,
        enclosureURL: String,
        clientRequestID: String,
        adAnalysis: AdAnalysisContext?
    ) -> OpenCastRemoteTranscriptionJobCreateRequest {
        OpenCastRemoteTranscriptionJobCreateRequest(
            clientRequestID: clientRequestID,
            episodeID: episode.episodeID,
            enclosureURL: enclosureURL,
            declaredDurationSeconds: episode.duration,
            languageCode: "en",
            sourceIdentity: downloads.completedSourceIdentity(for: episode.episodeID),
            adAnalysisRequested: adAnalysis != nil ? true : nil,
            podcastID: adAnalysis?.podcastID,
            episodeTitle: adAnalysis?.episodeTitle,
            podcastTitle: adAnalysis?.podcastTitle,
            mediaProfile: OpenCastMediaRequestProfile.version
        )
    }

    private func completedDownloadFileURL(
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) async throws -> URL {
        let record: EpisodeDownloadRecord
        do {
            record = try await downloads.ensureCompletedDownload(
                for: episode,
                modelContext: modelContext,
                onWaitStarted: { try Task.checkCancellation() }
            )
        } catch is DownloadStore.CompletedDownloadError {
            throw RemoteTranscriptionJobRunError.downloadFailed
        }
        guard let fileURL = downloads.localFileURL(for: record) else {
            throw RemoteTranscriptionJobRunError.downloadFailed
        }
        return fileURL
    }

    /// Drives the exact-device upload session and cleans its part files on
    /// every exit: success, cancellation, or failure. A thrown error surfaces
    /// through the normal failure mapping.
    private func uploadExactCopy(
        jobID: String,
        localFileURL: URL,
        onEvent: @escaping (RemoteTranscriptionJobEvent) -> Void
    ) async throws {
        onEvent(.uploadingExactCopy(completedParts: 0, totalParts: 0))
        let session = makeUploadSession(jobID, localFileURL)
        do {
            try await session.run { completed, total in
                onEvent(.uploadingExactCopy(completedParts: completed, totalParts: total))
            }
        } catch is CancellationError {
            await session.cancelAndCleanUp()
            throw CancellationError()
        } catch {
            await session.cancelAndCleanUp()
            throw error
        }
    }

    private func localSourceIdentity(
        episode: EpisodeListItemSnapshot,
        localFileURL: URL
    ) async throws -> OpenCastRemoteTranscriptionSourceIdentity {
        if let persisted = downloads.completedSourceIdentity(for: episode.episodeID) {
            return persisted
        }
        // Preexisting downloads from before hash persistence: compute the
        // definitive identity from the completed file now.
        let identity = try await EpisodeTranscriptionSourceIdentity.load(from: localFileURL)
        return OpenCastRemoteTranscriptionSourceIdentity(
            sha256: identity.sha256,
            byteCount: identity.byteCount,
            durationSeconds: identity.duration
        )
    }

    /// Polls until the job is terminal, has a result, or requests the
    /// exact-device upload (which the caller drives, then resumes polling).
    /// With `waitsForCredits` false, an `awaiting_credits` sighting returns
    /// immediately so the caller can bail instead of parking on the server's
    /// awaiting-credits deadline.
    private func pollUntilResult(
        trail: RunTrail,
        waitsForCredits: Bool,
        lastProgress: inout RemoteTranscriptionActiveProgress?,
        onEvent: (RemoteTranscriptionJobEvent) -> Void
    ) async throws -> OpenCastRemoteTranscriptionJobStatus {
        guard let jobID = trail.jobID else {
            throw RemoteTranscriptionJobRunError.localRequestFailed
        }
        var lastObservedState: OpenCastRemoteTranscriptionJobState?
        while true {
            try Task.checkCancellation()
            let response = try await performLeg(.poll, trail) { try await api.poll(jobID: jobID) }
            let job = response.job
            if job.state != lastObservedState {
                lastObservedState = job.state
                emit(trail, .pollObserved, leg: .poll, serverState: job.state)
            }
            switch job.state {
            case .resultReady, .delivered:
                return job
            case .acknowledged, .cancelled, .failed:
                return job
            case .exactUploadRequired, .exactUploading:
                return job
            case .awaitingCredits:
                guard waitsForCredits else {
                    return job
                }
                onEvent(.waitingForCredits)
            case .probing, .chunking, .reserved, .sourceMatched, .transcribing, .stitching:
                if let progress = progressTracker.activeProgress(for: job) {
                    lastProgress = progress
                    onEvent(.processing(progress))
                }
            case .detectingAds:
                onEvent(.detectingAds)
            case .created, .stagingOrigin, .waitingForDeviceSource:
                onEvent(.queuedRemotely)
            case .cancelling, .unknown:
                break
            }
            // Server-paced polling with client jitter; no duplicate submits
            // on transient poll failures because the job ID is stable.
            let jitter = Double.random(in: 0...1)
            try await Task.sleep(for: .seconds(Double(response.pollAfterSeconds) + jitter))
        }
    }

    /// The detect-only `awaiting_credits` bail: one `/cancel` on the
    /// unfunded reservation, then the reference is cleared so the offered
    /// device fallback is honest. Always throws.
    private func releaseUnfundedReservation(trail: RunTrail) async throws -> Never {
        if let jobID = trail.jobID {
            do {
                _ = try await api.cancel(jobID: jobID)
                emit(trail, .cancelAttempted, leg: .cancel, httpStatus: 200, disposition: .cancelAttempted)
            } catch {
                emit(trail, .cancelAttempted, leg: .cancel, error: error, disposition: .cancelAttempted)
            }
        }
        store.clearReference(for: trail.episodeID, purpose: trail.purpose)
        throw RemoteTranscriptionJobRunError.serverRejected(.insufficientCredits)
    }

    /// A poll answering `acknowledged` is success when this device already
    /// holds the transcript that job produced (import is idempotent by the
    /// job's provenance token). Without that provenance the server has
    /// already deleted its result, so nothing remains to fetch: the
    /// reference is cleared and the distinct outcome is the evidence.
    private func reconcileAcknowledged(trail: RunTrail) throws -> RemoteTranscriptionJobRunOutcome {
        defer {
            createRequests[ReferenceKey(episodeID: trail.episodeID, purpose: trail.purpose)] = nil
            store.clearReference(for: trail.episodeID, purpose: trail.purpose)
        }
        if let jobID = trail.jobID,
           transcriptions.record(for: trail.episodeID)?.engineProvenance == .remoteWhisper,
           let document = transcriptions.document(for: trail.episodeID),
           document.remoteJobProvenanceToken == jobID {
            emit(trail, .acknowledged, leg: .poll, serverState: .acknowledged, disposition: .cleared)
            return RemoteTranscriptionJobRunOutcome(jobID: jobID, document: document, adAnalysis: nil)
        }
        emit(trail, .acknowledgedWithoutLocalImport, leg: .poll, serverState: .acknowledged, disposition: .cleared)
        throw RemoteTranscriptionJobRunError.acknowledgedWithoutLocalImport
    }

    // MARK: Retry ladder

    /// Runs one request leg with the leg-aware ladder: transport errors use
    /// the transport delays, local errors (App Attest, keychain, decode) the
    /// short local delays, and landed HTTP, validation and download errors
    /// do not retry. Cancellation propagates immediately. Every attempt is
    /// recorded as a diagnostic event.
    private func performLeg<T>(
        _ leg: RemoteJobDiagnosticEvent.Leg,
        _ trail: RunTrail,
        _ operation: () async throws -> T
    ) async throws -> T {
        var transportDelays = transportRetryDelays[...]
        var localDelays = localRetryDelays[...]
        var attempt = 1
        let start = ContinuousClock.now
        emit(trail, .legStarted, leg: leg)
        while true {
            do {
                let value = try await operation()
                emit(trail, .legSucceeded, leg: leg, attempt: attempt, since: start)
                return value
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw error
                }
                let delay: Duration? = switch Self.retryClass(for: error) {
                case .transport: transportDelays.popFirst()
                case .local: localDelays.popFirst()
                case .none: nil
                }
                guard let delay else {
                    emit(trail, .legFailed, leg: leg, attempt: attempt, since: start, error: error)
                    throw error
                }
                emit(trail, .legRetried, leg: leg, attempt: attempt, error: error)
                attempt += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    private static func retryClass(for error: any Error) -> RetryClass {
        switch error {
        case is URLError:
            return .transport
        case let httpError as RemoteTranscriptionHTTPError:
            guard httpError.statusCode <= 0 else {
                return .none
            }
            if Self.isLocalClientCode(httpError.code) {
                return .local
            }
            return Self.isNonRetryableClientCode(httpError.code) ? .none : .transport
        case let appAttestError as AppAttestHTTPError:
            return appAttestError.statusCode <= 0 ? .transport : .none
        case is AppAttestKeychainError, is DecodingError:
            return .local
        case is DownloadStore.CompletedDownloadError,
             is EpisodeRemoteTranscriptMapper.ValidationError,
             is RemoteTranscriptionJobRunError:
            return .none
        default:
            return (error as NSError).domain == DCError.errorDomain ? .local : .none
        }
    }

    /// True for a client-side transport shape: the request may have left
    /// the process. Everything else is a local failure.
    private static func isTransportExit(_ error: any Error) -> Bool {
        switch error {
        case is URLError:
            return true
        case let httpError as RemoteTranscriptionHTTPError:
            return httpError.statusCode <= 0
                && !Self.isLocalClientCode(httpError.code)
                && !Self.isNonRetryableClientCode(httpError.code)
        case let appAttestError as AppAttestHTTPError:
            return appAttestError.statusCode <= 0
        default:
            return false
        }
    }

    /// Client-side codes the API layer raises before or after a request
    /// without any HTTP exchange landing, which behave like decode failures.
    private static func isLocalClientCode(_ code: String) -> Bool {
        code == "invalid_response" || code == "response_too_large"
    }

    /// Client-side codes for configuration states (feature disabled, App
    /// Attest or AppTransaction unavailable) and download outcomes, which a
    /// retry cannot change.
    private static func isNonRetryableClientCode(_ code: String) -> Bool {
        switch OpenCastRemoteTranscriptionErrorCode(wireValue: code) {
        case .featureDisabled, .unauthorized, .invalidRequest:
            true
        default:
            code == "download_failed" || code == "missing_local_file"
        }
    }

    // MARK: Exit disposition

    /// Maps a leg's final error onto the reference's exit and the thrown run
    /// error, by run stage (CONTRACTS §3 for the create leg, §5 afterwards).
    private func exitDisposition(
        for error: any Error,
        stage: RunStage,
        isFirstAttempt: Bool,
        trail: RunTrail
    ) -> RemoteTranscriptionJobRunError {
        let episodeID = trail.episodeID
        let purpose = trail.purpose
        if let httpError = error as? RemoteTranscriptionHTTPError {
            if httpError.statusCode > 0 {
                return landedDisposition(httpError, stage: stage, isFirstAttempt: isFirstAttempt, trail: trail)
            }
            if httpError.code == "download_failed" || httpError.code == "missing_local_file" {
                store.recordExit(.downloadFailed, episodeID: episodeID, purpose: purpose)
                return .downloadFailed
            }
        }
        let isTransport = Self.isTransportExit(error)
        switch stage {
        case .beforeCreate:
            guard isTransport else {
                store.recordExit(.localRequestFailed, episodeID: episodeID, purpose: purpose)
                return .localRequestFailed
            }
            // No attempt was marked, so the prepared reference is simply
            // reused by Try Again.
            return .serviceUnavailable
        case .creating:
            // The request may have reached the server: the attempt stays
            // marked and the same client request ID resolves it later.
            let exit: RemoteTranscriptionJobExit = isTransport ? .connectionLost : .localRequestFailed
            store.recordExit(exit, episodeID: episodeID, purpose: purpose)
            emit(trail, .createUncertain, leg: .create, error: error, disposition: .retained)
            return isTransport ? .connectionLost : .localRequestFailed
        case .attached:
            let exit: RemoteTranscriptionJobExit = isTransport ? .connectionLost : .localRequestFailed
            store.recordExit(exit, episodeID: episodeID, purpose: purpose)
            return isTransport ? .connectionLost : .localRequestFailed
        }
    }

    private func landedDisposition(
        _ error: RemoteTranscriptionHTTPError,
        stage: RunStage,
        isFirstAttempt: Bool,
        trail: RunTrail
    ) -> RemoteTranscriptionJobRunError {
        let episodeID = trail.episodeID
        let purpose = trail.purpose
        if error.errorCode == .sourceMismatch {
            store.clearReference(for: episodeID, purpose: purpose)
            return .mismatchLocalFallback
        }
        switch stage {
        case .beforeCreate:
            break
        case .creating:
            // A first-attempt 4xx is conclusive: the Worker validates before
            // inserting the mapping. A repeated 4xx or any 5xx keeps the
            // attempt marked because an earlier attempt may have mapped.
            if isFirstAttempt, (400..<500).contains(error.statusCode) {
                store.clearReference(for: episodeID, purpose: purpose)
            }
        case .attached:
            if error.errorCode == .jobNotFound {
                store.clearReference(for: episodeID, purpose: purpose)
            }
        }
        return .serverRejected(error.errorCode)
    }

    private func finalizingProgress(
        after prior: RemoteTranscriptionActiveProgress?
    ) -> RemoteTranscriptionActiveProgress {
        RemoteTranscriptionActiveProgress(
            stage: .finalizing,
            completedChunks: prior?.completedChunks,
            totalChunks: prior?.totalChunks,
            fractionCompleted: prior?.fractionCompleted,
            estimate: nil
        )
    }

    private func terminalFailure(
        for status: OpenCastRemoteTranscriptionJobStatus
    ) -> RemoteTranscriptionJobRunError? {
        switch status.state {
        case .cancelled:
            return .remoteCancelled
        case .failed:
            if status.error?.code == .sourceMismatch {
                return .mismatchLocalFallback
            }
            return .serverRejected(status.error?.code ?? .internalError)
        default:
            return nil
        }
    }

    // MARK: Diagnostics

    private func emit(
        _ trail: RunTrail,
        _ kind: RemoteJobDiagnosticEvent.Kind,
        leg: RemoteJobDiagnosticEvent.Leg? = nil,
        attempt: Int? = nil,
        since start: ContinuousClock.Instant? = nil,
        httpStatus: Int? = nil,
        serverState: OpenCastRemoteTranscriptionJobState? = nil,
        error: (any Error)? = nil,
        disposition: RemoteJobDiagnosticEvent.Disposition? = nil
    ) {
        let landedStatus = (error as? RemoteTranscriptionHTTPError).map(\.statusCode)
        store.diagnostics.record(RemoteJobDiagnosticEvent(
            component: .runner,
            kind: kind,
            episodeID: trail.episodeID,
            jobID: trail.jobID,
            clientRequestID: trail.clientRequestID,
            purpose: trail.purpose,
            leg: leg,
            attempt: attempt,
            elapsedMilliseconds: start.map { Int($0.duration(to: .now) / .milliseconds(1)) },
            httpStatus: httpStatus ?? landedStatus,
            serverState: serverState,
            error: error.map(RemoteJobDiagnosticError.init(classifying:)),
            disposition: disposition
        ))
    }
}
