import Foundation
import Observation
import OpenCastTranscription
import SwiftData

/// Orchestrates exactly one remote transcription request: bootstrap →
/// create/attach job while the explicit episode download starts/reuses →
/// report exact local source identity → poll with the server's pacing plus
/// jitter → drive the exact-device upload when (and only when) the server
/// requests it → fetch/validate result → import → ack only after the durable
/// local write → refresh balance. A prior completed transcript is preserved
/// until the new document commits.
@Observable
final class EpisodeRemoteTranscriptionCoordinator {
    typealias UploadSessionFactory = (_ jobID: String, _ sourceFileURL: URL) -> RemoteTranscriptionUploadSession

    private let api: any RemoteTranscriptionAPI
    private let downloads: DownloadStore
    private let transcriptions: EpisodeTranscriptionStore
    @ObservationIgnored private let makeUploadSession: UploadSessionFactory
    @ObservationIgnored private let progressTracker = RemoteTranscriptionProgressTracker()
    let store: RemoteTranscriptionJobStore

    init(
        api: any RemoteTranscriptionAPI,
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        store: RemoteTranscriptionJobStore = RemoteTranscriptionJobStore(),
        uploadSessionFactory: UploadSessionFactory? = nil
    ) {
        self.api = api
        self.downloads = downloads
        self.transcriptions = transcriptions
        self.store = store
        makeUploadSession = uploadSessionFactory ?? { jobID, sourceFileURL in
            RemoteTranscriptionUploadSession(
                jobID: jobID,
                sourceFileURL: sourceFileURL,
                api: api,
                transport: BackgroundRemoteTranscriptionUploadTransport(jobID: jobID)
            )
        }
    }

    func start(episode: EpisodeListItemSnapshot, modelContext: ModelContext) {
        guard !store.hasActiveRequest else {
            return
        }
        guard let audioURL = episode.audioURL, audioURL.isEmpty == false else {
            store.begin(episodeID: episode.episodeID, title: episode.title)
            store.finish(phase: .failed(.missingAudio))
            return
        }

        store.begin(episodeID: episode.episodeID, title: episode.title)
        store.activeTask = Task { [weak self] in
            await self?.run(episode: episode, enclosureURL: audioURL, modelContext: modelContext)
        }
    }

    func cancel() {
        store.cancelActiveRequest()
    }

    private func run(
        episode: EpisodeListItemSnapshot,
        enclosureURL: String,
        modelContext: ModelContext
    ) async {
        var jobID: String?
        defer {
            if let jobID {
                progressTracker.remove(jobID: jobID)
            }
        }
        do {
            let bootstrap = try await api.bootstrap()
            store.updateAccount(bootstrap)

            store.update(phase: .downloadingBoth)
            let reference = store.reference(for: episode.episodeID)
            let created = try await api.createJob(
                OpenCastRemoteTranscriptionJobCreateRequest(
                    clientRequestID: reference.clientRequestID,
                    episodeID: episode.episodeID,
                    enclosureURL: enclosureURL,
                    declaredDurationSeconds: episode.duration,
                    languageCode: "en",
                    sourceIdentity: downloads.completedSourceIdentity(for: episode.episodeID)
                )
            )
            jobID = created.job.jobID
            store.attachJob(id: created.job.jobID, episodeID: episode.episodeID)

            // The explicit local download runs concurrently with the server's
            // origin fetch; policy stays foreground/local-only.
            let localFileURL = try await completedDownloadFileURL(
                episode: episode,
                modelContext: modelContext
            )
            store.update(phase: .verifying)
            let identity = try await localSourceIdentity(
                episode: episode,
                localFileURL: localFileURL
            )
            _ = try await api.reportSource(jobID: created.job.jobID, identity: identity)

            var finalStatus = try await pollUntilResult(jobID: created.job.jobID)
            if finalStatus.state == .exactUploadRequired || finalStatus.state == .exactUploading {
                // The server could not stage or prove the origin bytes; the
                // user already asked for this transcript, so the exact-copy
                // upload engages without a second confirmation.
                try await uploadExactCopy(jobID: created.job.jobID, localFileURL: localFileURL)
                finalStatus = try await pollUntilResult(jobID: created.job.jobID)
            }
            if let outcome = terminalOutcome(for: finalStatus) {
                store.clearReference(for: episode.episodeID)
                store.finish(phase: outcome)
                return
            }

            store.update(phase: finalizingPhase())
            let resultResponse = try await api.result(jobID: created.job.jobID)

            store.update(phase: .saving)
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
            store.clearReference(for: episode.episodeID)
            if let refreshed = try? await api.bootstrap() {
                store.updateAccount(refreshed)
            }
            store.finish(phase: .completed)
        } catch is CancellationError {
            if let jobID {
                let cancelClient = api
                Task.detached {
                    _ = try? await cancelClient.cancel(jobID: jobID)
                }
            }
            store.finish(phase: .cancelled)
        } catch let error as RemoteTranscriptionHTTPError {
            store.finish(phase: phaseForHTTPError(error))
        } catch is EpisodeRemoteTranscriptMapper.ValidationError {
            store.finish(phase: .failed(.resultInvalid))
        } catch {
            // Transport errors (URLError and friends) from bootstrap, create,
            // poll, or result: the backend was unreachable mid-flow.
            store.finish(phase: .failed(.serviceUnavailable))
        }
    }

    private func completedDownloadFileURL(
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) async throws -> URL {
        var didStartDownload = false
        while true {
            try Task.checkCancellation()
            if let record = downloads.record(for: episode.episodeID) {
                switch record.state {
                case .completed:
                    guard let fileURL = downloads.localFileURL(for: record) else {
                        throw RemoteTranscriptionHTTPError(
                            statusCode: -1,
                            code: "missing_local_file",
                            detail: nil
                        )
                    }
                    return fileURL
                case .downloading:
                    try await downloads.waitForDownload(episodeID: episode.episodeID)
                case .paused, .failed, .missing:
                    guard !didStartDownload else {
                        throw RemoteTranscriptionHTTPError(
                            statusCode: -1,
                            code: "download_failed",
                            detail: record.errorMessage
                        )
                    }
                    downloads.startDownload(for: episode, modelContext: modelContext)
                    didStartDownload = true
                    try await downloads.waitForDownload(episodeID: episode.episodeID)
                }
            } else {
                downloads.startDownload(for: episode, modelContext: modelContext)
                didStartDownload = true
                try await downloads.waitForDownload(episodeID: episode.episodeID)
            }
        }
    }

    /// Drives the exact-device upload session and cleans its part files on
    /// every exit: success, cancellation, or failure (decision 6). A thrown
    /// error surfaces through the normal failure mapping.
    private func uploadExactCopy(jobID: String, localFileURL: URL) async throws {
        store.update(phase: .uploadingExactCopy(completedParts: 0, totalParts: 0))
        let session = makeUploadSession(jobID, localFileURL)
        do {
            try await session.run { [store] completed, total in
                store.update(phase: .uploadingExactCopy(completedParts: completed, totalParts: total))
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
    private func pollUntilResult(jobID: String) async throws -> OpenCastRemoteTranscriptionJobStatus {
        while true {
            try Task.checkCancellation()
            let response = try await api.poll(jobID: jobID)
            let job = response.job
            switch job.state {
            case .resultReady, .delivered:
                return job
            case .acknowledged, .cancelled, .failed:
                return job
            case .exactUploadRequired, .exactUploading:
                return job
            case .awaitingCredits:
                store.update(phase: .waitingForCredits)
            case .probing, .chunking, .reserved, .sourceMatched, .transcribing, .stitching:
                if let progress = progressTracker.activeProgress(for: job) {
                    store.update(phase: .processing(progress))
                }
            case .created, .stagingOrigin, .waitingForDeviceSource:
                store.update(phase: .downloadingBoth)
            case .cancelling, .unknown:
                break
            }
            // Server-paced polling with client jitter; no duplicate submits
            // on transient poll failures because the job ID is stable.
            let jitter = Double.random(in: 0...1)
            try await Task.sleep(for: .seconds(Double(response.pollAfterSeconds) + jitter))
        }
    }

    private func finalizingPhase() -> RemoteTranscriptionRequestPhase {
        let prior: RemoteTranscriptionActiveProgress? = if case let .processing(progress) = store.phase {
            progress
        } else {
            nil
        }
        return .processing(RemoteTranscriptionActiveProgress(
            stage: .finalizing,
            completedChunks: prior?.completedChunks,
            totalChunks: prior?.totalChunks,
            fractionCompleted: prior?.fractionCompleted,
            estimate: nil
        ))
    }

    private func terminalOutcome(
        for status: OpenCastRemoteTranscriptionJobStatus
    ) -> RemoteTranscriptionRequestPhase? {
        switch status.state {
        case .resultReady, .delivered:
            nil
        case .cancelled:
            .cancelled
        case .failed, .acknowledged:
            if status.error?.code == .sourceMismatch {
                .mismatchLocalFallback
            } else {
                .failed(.serverRejected(status.error?.code ?? .internalError))
            }
        default:
            nil
        }
    }

    private func phaseForHTTPError(_ error: RemoteTranscriptionHTTPError) -> RemoteTranscriptionRequestPhase {
        if error.errorCode == .sourceMismatch {
            return .mismatchLocalFallback
        }
        switch error.code {
        case "download_failed", "missing_local_file":
            return .failed(.downloadFailed)
        default:
            // A non-positive status is client-side (no HTTP exchange landed).
            return .failed(error.statusCode > 0 ? .serverRejected(error.errorCode) : .serviceUnavailable)
        }
    }
}
