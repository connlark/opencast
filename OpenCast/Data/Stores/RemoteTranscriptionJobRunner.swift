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
/// `RemoteTranscriptionJobRunError`; `CancellationError` passes through after
/// a fire-and-forget server cancel.
final class RemoteTranscriptionJobRunner {
    typealias UploadSessionFactory = (_ jobID: String, _ sourceFileURL: URL) -> RemoteTranscriptionUploadSession

    /// Extra create-request context for a detect-ads job: the server chains
    /// ad detection after stitching under this podcast identity.
    struct AdAnalysisContext {
        let podcastID: String
        let episodeTitle: String?
        let podcastTitle: String?
    }

    /// Grace for transient backend loss (≈2¼ minutes total): long enough to
    /// ride out a Wi-Fi handoff mid-poll, short enough that a genuinely dead
    /// backend still fails the run promptly.
    static let defaultTransportRetryDelays: [Duration] = [
        .seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60),
    ]

    private let api: any RemoteTranscriptionAPI
    private let downloads: DownloadStore
    private let transcriptions: EpisodeTranscriptionStore
    private let store: RemoteTranscriptionJobStore
    private let makeUploadSession: UploadSessionFactory
    private let transportRetryDelays: [Duration]
    private let progressTracker = RemoteTranscriptionProgressTracker()

    init(
        api: any RemoteTranscriptionAPI,
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        store: RemoteTranscriptionJobStore,
        uploadSessionFactory: UploadSessionFactory? = nil,
        transportRetryDelays: [Duration] = RemoteTranscriptionJobRunner.defaultTransportRetryDelays
    ) {
        self.api = api
        self.downloads = downloads
        self.transcriptions = transcriptions
        self.store = store
        self.transportRetryDelays = transportRetryDelays
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
        var jobID: String?
        defer {
            if let jobID {
                progressTracker.remove(jobID: jobID)
            }
        }
        do {
            let bootstrap = try await api.bootstrap()
            store.updateAccount(bootstrap)

            onEvent(.downloading)
            let reference = store.reference(for: episode.episodeID, purpose: purpose)
            let created = try await api.createJob(
                OpenCastRemoteTranscriptionJobCreateRequest(
                    clientRequestID: reference.clientRequestID,
                    episodeID: episode.episodeID,
                    enclosureURL: enclosureURL,
                    declaredDurationSeconds: episode.duration,
                    languageCode: "en",
                    sourceIdentity: downloads.completedSourceIdentity(for: episode.episodeID),
                    adAnalysisRequested: adAnalysis != nil ? true : nil,
                    podcastID: adAnalysis?.podcastID,
                    episodeTitle: adAnalysis?.episodeTitle,
                    podcastTitle: adAnalysis?.podcastTitle
                )
            )
            jobID = created.job.jobID
            store.attachJob(id: created.job.jobID, episodeID: episode.episodeID, purpose: purpose)

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
            _ = try await api.reportSource(jobID: created.job.jobID, identity: identity)

            var lastProgress: RemoteTranscriptionActiveProgress?
            var finalStatus = try await pollUntilResult(
                jobID: created.job.jobID,
                waitsForCredits: purpose == .transcription,
                lastProgress: &lastProgress,
                onEvent: onEvent
            )
            if finalStatus.state == .exactUploadRequired || finalStatus.state == .exactUploading {
                // The server could not stage or prove the origin bytes; the
                // user already asked for this transcript, so the exact-copy
                // upload engages without a second confirmation.
                try await uploadExactCopy(
                    jobID: created.job.jobID,
                    localFileURL: localFileURL,
                    onEvent: onEvent
                )
                finalStatus = try await pollUntilResult(
                    jobID: created.job.jobID,
                    waitsForCredits: purpose == .transcription,
                    lastProgress: &lastProgress,
                    onEvent: onEvent
                )
            }
            if finalStatus.state == .awaitingCredits {
                // A detect pass never parks on credits — that would block the
                // whole queue for the server's awaiting-credits deadline.
                // Nothing has been charged while the reservation is unfunded,
                // so cancel and surface the one-tap device fallback.
                _ = try? await api.cancel(jobID: created.job.jobID)
                store.clearReference(for: episode.episodeID, purpose: purpose)
                throw RemoteTranscriptionJobRunError.serverRejected(.insufficientCredits)
            }
            if let failure = terminalFailure(for: finalStatus) {
                store.clearReference(for: episode.episodeID, purpose: purpose)
                throw failure
            }

            onEvent(.processing(finalizingProgress(after: lastProgress)))
            let resultResponse = try await withTransportRetry {
                try await api.result(jobID: created.job.jobID)
            }

            onEvent(.saving)
            let document = try EpisodeRemoteTranscriptMapper.document(
                from: resultResponse.result,
                context: EpisodeRemoteTranscriptMapper.Context(
                    episodeID: episode.episodeID,
                    podcastID: episode.podcastID,
                    sourceAudioURL: enclosureURL,
                    localIdentity: identity,
                    jobProvenanceToken: created.job.jobID
                )
            )
            try await transcriptions.importRemoteTranscript(document, modelContext: modelContext)

            // Ack only after the durable local import; an ack failure is the
            // server's recovery problem (result TTL), never a user failure.
            _ = try? await api.ack(
                jobID: created.job.jobID,
                normalizedTranscriptSHA256: document.normalizedTranscriptSHA256
            )
            store.clearReference(for: episode.episodeID, purpose: purpose)
            if let refreshed = try? await api.bootstrap() {
                store.updateAccount(refreshed)
            }
            return RemoteTranscriptionJobRunOutcome(
                jobID: created.job.jobID,
                document: document,
                adAnalysis: resultResponse.adAnalysis
            )
        } catch is CancellationError {
            if let jobID {
                let cancelClient = api
                Task.detached {
                    _ = try? await cancelClient.cancel(jobID: jobID)
                }
            }
            throw CancellationError()
        } catch let error as RemoteTranscriptionJobRunError {
            throw error
        } catch let error as RemoteTranscriptionHTTPError {
            let mapped = runError(for: error)
            if mapped == .serviceUnavailable {
                abandonUnreachableJob(jobID: jobID, episodeID: episode.episodeID, purpose: purpose)
            }
            throw mapped
        } catch is EpisodeRemoteTranscriptMapper.ValidationError {
            throw RemoteTranscriptionJobRunError.resultInvalid
        } catch {
            // Transport errors (URLError and friends) from bootstrap, create,
            // poll, or result: the backend was unreachable past the bounded
            // retry grace.
            abandonUnreachableJob(jobID: jobID, episodeID: episode.episodeID, purpose: purpose)
            throw RemoteTranscriptionJobRunError.serviceUnavailable
        }
    }

    /// A detect pass that loses the backend after create surfaces the one-tap
    /// device fallback, so the server job must not keep charging toward an
    /// unclaimed transcript: fire a best-effort cancel (free until credits
    /// settle at stitch) and drop the reference so the fallback is honest.
    /// Plain transcription keeps its reference — its retry affordance
    /// re-attaches to the same job and recovers the paid work.
    private func abandonUnreachableJob(
        jobID: String?,
        episodeID: String,
        purpose: RemoteTranscriptionJobPurpose
    ) {
        guard purpose == .adDetection, let jobID else {
            return
        }
        let cancelClient = api
        Task.detached {
            _ = try? await cancelClient.cancel(jobID: jobID)
        }
        store.clearReference(for: episodeID, purpose: purpose)
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
        jobID: String,
        waitsForCredits: Bool,
        lastProgress: inout RemoteTranscriptionActiveProgress?,
        onEvent: (RemoteTranscriptionJobEvent) -> Void
    ) async throws -> OpenCastRemoteTranscriptionJobStatus {
        while true {
            try Task.checkCancellation()
            let response = try await withTransportRetry { try await api.poll(jobID: jobID) }
            let job = response.job
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

    /// Poll and result are idempotent against a stable job ID, so transient
    /// transport loss retries with bounded backoff instead of failing a job
    /// the server is still running. Server responses (any landed HTTP
    /// exchange) and cancellation propagate immediately.
    private func withTransportRetry<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        var remainingDelays = transportRetryDelays[...]
        while true {
            do {
                return try await operation()
            } catch let error where Self.isTransientTransportError(error) {
                guard let delay = remainingDelays.first else {
                    throw error
                }
                remainingDelays = remainingDelays.dropFirst()
                try await Task.sleep(for: delay)
            }
        }
    }

    private static func isTransientTransportError(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        // A non-positive status is client-side: no HTTP exchange landed.
        if let httpError = error as? RemoteTranscriptionHTTPError {
            return httpError.statusCode <= 0
        }
        return false
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
        case .failed, .acknowledged:
            if status.error?.code == .sourceMismatch {
                return .mismatchLocalFallback
            }
            return .serverRejected(status.error?.code ?? .internalError)
        default:
            return nil
        }
    }

    private func runError(for error: RemoteTranscriptionHTTPError) -> RemoteTranscriptionJobRunError {
        if error.errorCode == .sourceMismatch {
            return .mismatchLocalFallback
        }
        switch error.code {
        case "download_failed", "missing_local_file":
            return .downloadFailed
        default:
            // A non-positive status is client-side (no HTTP exchange landed).
            return error.statusCode > 0
                ? .serverRejected(error.errorCode)
                : .serviceUnavailable
        }
    }
}
