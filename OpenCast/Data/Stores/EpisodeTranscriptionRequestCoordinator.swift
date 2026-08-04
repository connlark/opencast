import Foundation
import Observation
import SwiftData

@Observable
final class EpisodeTranscriptionRequestCoordinator {
    private(set) var request: EpisodeTranscriptionRequest?
    private(set) var isPresented = false

    private let library: LibraryStore
    private let downloads: DownloadStore
    private let transcriptionModels: TranscriptionModelStore
    private let transcriptionEngineSettings: TranscriptionEngineSettingsStore
    private let appleSpeechAssets: AppleSpeechAssetStore
    private let transcriptions: EpisodeTranscriptionStore
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private var localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation?
    @ObservationIgnored var onPhaseChange: ((EpisodeTranscriptionRequestPhase) -> Void)?

    init(
        library: LibraryStore,
        downloads: DownloadStore,
        transcriptionModels: TranscriptionModelStore,
        transcriptionEngineSettings: TranscriptionEngineSettingsStore,
        appleSpeechAssets: AppleSpeechAssetStore,
        transcriptions: EpisodeTranscriptionStore
    ) {
        self.library = library
        self.downloads = downloads
        self.transcriptionModels = transcriptionModels
        self.transcriptionEngineSettings = transcriptionEngineSettings
        self.appleSpeechAssets = appleSpeechAssets
        self.transcriptions = transcriptions
    }

    func start(
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext,
        prepareBackgroundSession: (() -> Void)? = nil
    ) {
        if let request,
           request.episodeID == episode.episodeID,
           !request.phase.isTerminal {
            isPresented = true
            return
        }

        guard requestTask == nil else {
            failRequest(
                episode: episode,
                message: EpisodeTranscriptionWorkCoordinator.Conflict.anotherLocalTranscription.localizedDescription
            )
            return
        }

        let reservation: EpisodeTranscriptionWorkCoordinator.LocalReservation
        let reservationResult: Result<
            EpisodeTranscriptionWorkCoordinator.LocalReservation,
            EpisodeTranscriptionWorkCoordinator.Conflict
        >
        if transcriptions.hasActiveJob {
            guard transcriptions.activeEpisodeID == episode.episodeID else {
                failRequest(
                    episode: episode,
                    message: EpisodeTranscriptionWorkCoordinator.Conflict.anotherLocalTranscription.localizedDescription
                )
                return
            }
            reservationResult = transcriptions.workCoordinator.joinLocal(
                episodeID: episode.episodeID
            )
        } else {
            reservationResult = transcriptions.reserveLocalWork(for: episode.episodeID)
        }
        switch reservationResult {
        case .success(let value):
            reservation = value
        case .failure(let conflict):
            failRequest(episode: episode, message: conflict.localizedDescription)
            return
        }

        let newRequest = EpisodeTranscriptionRequest(
            episodeID: episode.episodeID,
            episodeTitle: episode.title,
            phase: initialPhase(for: episode.episodeID)
        )
        request = newRequest
        isPresented = true
        activeRequestID = newRequest.id
        localReservation = reservation

        if transcriptions.isActivelyTranscribing(episodeID: episode.episodeID) {
            requestTask = Task { [weak self] in
                await self?.attach(
                    requestID: newRequest.id,
                    episodeID: episode.episodeID,
                    modelContext: modelContext
                )
            }
        } else {
            prepareBackgroundSession?()
            requestTask = Task { [weak self] in
                await self?.run(
                    requestID: newRequest.id,
                    episode: episode,
                    modelContext: modelContext
                )
            }
        }
    }

    func dismiss(id: UUID) {
        guard request?.id == id else {
            return
        }
        isPresented = false
    }

    func resetForDataNuke() {
        let task = requestTask
        if let localReservation {
            transcriptions.releaseLocalWork(localReservation)
        }
        activeRequestID = nil
        localReservation = nil
        requestTask = nil
        request = nil
        isPresented = false
        task?.cancel()
    }

    func prepareForLifecycleExit(modelContext: ModelContext) {
        transcriptions.interruptActiveJob(modelContext: modelContext)
    }

    private func run(
        requestID: UUID,
        episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) async {
        defer {
            finishRequest(id: requestID)
        }

        do {
            let downloadRecord = try await completedDownload(
                episode,
                requestID: requestID,
                modelContext: modelContext
            )
            try ensureCurrentRequest(id: requestID)

            if let activeEngine = transcriptions.activeEngine(for: episode.episodeID) {
                // An ad-free pass may already be transcribing this episode,
                // possibly with Apple Speech; attach instead of competing.
                updatePhase(
                    activeEngine == .appleSpeech ? .transcribingAppleSpeech : .transcribingWhisper,
                    requestID: requestID
                )
                try await waitForTranscriptionToStop(episodeID: episode.episodeID)
            } else if transcriptions.hasActiveJob {
                throw EpisodeTranscriptionRequestError.operationFailed(
                    "Another transcript is already in progress."
                )
            } else if transcriptions.record(for: episode.episodeID)?.state == .completed {
                try requireCompletedDocument(
                    episodeID: episode.episodeID,
                    modelContext: modelContext
                )
                updatePhase(.completed, requestID: requestID)
                return
            } else {
                let plan = try await resolvePlan(
                    for: episode,
                    requestID: requestID,
                    modelContext: modelContext
                )
                try ensureCurrentRequest(id: requestID)
                updatePhase(
                    plan.runEngine == .appleSpeech ? .transcribingAppleSpeech : .transcribingWhisper,
                    requestID: requestID
                )
                guard let localFileURL = downloads.localFileURL(for: downloadRecord),
                      downloads.downloadedFileExists(for: downloadRecord)
                else {
                    throw EpisodeTranscriptionError.missingDownloadedFile
                }
                guard transcriptions.startTranscription(
                    episode,
                    downloadRecord: downloadRecord,
                    localFileURL: localFileURL,
                    engine: plan.runEngine,
                    modelIdentity: plan.modelIdentity,
                    languageCode: plan.languageCode,
                    runLanguageCode: plan.runLanguageCode,
                    localReservation: localReservation,
                    modelContext: modelContext
                ) else {
                    throw EpisodeTranscriptionRequestError.operationFailed(
                        transcriptions.lastErrorMessage(for: episode.episodeID)
                            ?? "Unable to start transcription."
                    )
                }
                try await waitForTranscriptionToStop(episodeID: episode.episodeID)
            }

            try ensureCurrentRequest(id: requestID)
            guard let record = transcriptions.record(for: episode.episodeID) else {
                throw EpisodeTranscriptionRequestError.operationFailed(
                    "Transcription stopped without saving its state."
                )
            }

            switch record.state {
            case .completed:
                try requireCompletedDocument(
                    episodeID: episode.episodeID,
                    modelContext: modelContext
                )
                updatePhase(.completed, requestID: requestID)
            case .interrupted:
                updateInterruptedPhase(
                    episodeID: episode.episodeID,
                    requestID: requestID
                )
            case .failed:
                throw EpisodeTranscriptionRequestError.operationFailed(
                    record.errorMessage
                        ?? transcriptions.lastErrorMessage(for: episode.episodeID)
                        ?? "Transcription failed without an error message."
                )
            case .cancelled:
                updatePhase(.cancelled, requestID: requestID)
            case .queued, .running:
                throw EpisodeTranscriptionRequestError.operationFailed(
                    "Transcription stopped in an invalid state."
                )
            }
        } catch is CancellationError {
            return
        } catch {
            updatePhase(.failed(error.localizedDescription), requestID: requestID)
        }
    }

    private func requireCompletedDocument(
        episodeID: String,
        modelContext: ModelContext
    ) throws {
        guard transcriptions.hasCompletedDocument(for: episodeID) else {
            transcriptions.markTranscriptDocumentUnavailable(
                episodeID: episodeID,
                modelContext: modelContext
            )
            throw EpisodeTranscriptionError.transcriptDocumentMissing
        }
    }

    private func completedDownload(
        _ episode: EpisodeListItemSnapshot,
        requestID: UUID,
        modelContext: ModelContext
    ) async throws -> EpisodeDownloadRecord {
        do {
            return try await downloads.ensureCompletedDownload(
                for: episode,
                modelContext: modelContext,
                onWaitStarted: {
                    try ensureCurrentRequest(id: requestID)
                    updatePhase(.downloading, requestID: requestID)
                }
            )
        } catch DownloadStore.CompletedDownloadError.fileMissing {
            throw EpisodeTranscriptionError.missingDownloadedFile
        } catch let DownloadStore.CompletedDownloadError.notCompleted(_, errorMessage) {
            throw EpisodeTranscriptionRequestError.operationFailed(
                errorMessage ?? "The episode download did not complete."
            )
        }
    }

    /// Fresh Generate runs follow the global preference. A resumable Whisper
    /// record stays on Whisper even when Apple Speech is preferred so the
    /// explicit Resume action preserves its checkpoint.
    private func resolvePlan(
        for episode: EpisodeListItemSnapshot,
        requestID: UUID,
        modelContext: ModelContext
    ) async throws -> EpisodeTranscriptionPlan {
        var didEnsureTinyModel = false
        while true {
            try ensureCurrentRequest(id: requestID)
            updatePhase(.preparingWhisper, requestID: requestID)
            let resolver = EpisodeTranscriptionPlanResolver(
                transcriptionModels: transcriptionModels,
                appleSpeechAssets: appleSpeechAssets,
                prefersRevocationDurableEngine: !transcriptionEngineSettings.prefersAppleSpeech
                    || transcriptions.hasResumableWhisperCheckpoint(for: episode.episodeID)
            )

            do {
                let plan = try await resolver.resolve(
                    requestedEngine: .productDefault,
                    podcastLanguageCode: library.podcastCache(for: episode.podcastID)?.languageCode
                )
                try ensureCurrentRequest(id: requestID)
                return plan
            } catch EpisodeTranscriptionError.missingSpeechModel {
                try ensureCurrentRequest(id: requestID)
                // One ensure round is the legitimate install path. If the
                // store then reports installed but resolution still cannot
                // see the model, retrying cannot converge — and this loop
                // never suspends, so spinning would hang the main actor.
                guard !didEnsureTinyModel else {
                    throw EpisodeTranscriptionRequestError.operationFailed(
                        "The Whisper model install did not produce a usable model."
                    )
                }
                try await ensureTinyWhisperModel(requestID: requestID, modelContext: modelContext)
                didEnsureTinyModel = true
            }
        }
    }

    private func ensureTinyWhisperModel(
        requestID: UUID,
        modelContext: ModelContext
    ) async throws {
        try ensureCurrentRequest(id: requestID)
        updatePhase(.preparingWhisper, requestID: requestID)
        if transcriptionModels.selectedChoice != .fastTinyEnglish {
            guard transcriptionModels.setSelectedChoice(.fastTinyEnglish, modelContext: modelContext) else {
                throw EpisodeTranscriptionRequestError.operationFailed(
                    "Unable to select the Whisper model."
                )
            }
        }

        var didStartInstall = false
        while true {
            try ensureCurrentRequest(id: requestID)
            let sequence = transcriptionModels.changeSequence
            switch transcriptionModels.state {
            case .installed:
                return
            case .notInstalled, .unknown, .repairAvailable:
                guard !didStartInstall, transcriptionModels.installPinnedModel() else {
                    throw EpisodeTranscriptionRequestError.operationFailed(
                        "Unable to install the Whisper model."
                    )
                }
                didStartInstall = true
            case .failed(let message):
                guard !didStartInstall, transcriptionModels.installPinnedModel() else {
                    throw EpisodeTranscriptionRequestError.operationFailed(message)
                }
                didStartInstall = true
            case .checking, .installing, .deleting:
                break
            }
            try await transcriptionModels.waitForChange(after: sequence)
        }
    }

    private func waitForTranscriptionToStop(episodeID: String) async throws {
        try await transcriptions.waitForActiveJobToStop(episodeID: episodeID)
    }

    private func finishRequest(id: UUID) {
        guard activeRequestID == id else {
            return
        }
        activeRequestID = nil
        requestTask = nil
        if let localReservation {
            transcriptions.releaseLocalWork(localReservation)
            self.localReservation = nil
        }
    }

    private func attach(
        requestID: UUID,
        episodeID: String,
        modelContext: ModelContext
    ) async {
        defer {
            finishRequest(id: requestID)
        }

        do {
            try await waitForTranscriptionToStop(episodeID: episodeID)
            try ensureCurrentRequest(id: requestID)
            guard let record = transcriptions.record(for: episodeID) else {
                throw EpisodeTranscriptionRequestError.operationFailed(
                    "Transcription stopped without saving its state."
                )
            }
            switch record.state {
            case .completed:
                try requireCompletedDocument(episodeID: episodeID, modelContext: modelContext)
                updatePhase(.completed, requestID: requestID)
            case .interrupted:
                updateInterruptedPhase(episodeID: episodeID, requestID: requestID)
            case .failed:
                throw EpisodeTranscriptionRequestError.operationFailed(
                    record.errorMessage ?? "Transcription failed without an error message."
                )
            case .cancelled:
                updatePhase(.cancelled, requestID: requestID)
            case .queued, .running:
                throw EpisodeTranscriptionRequestError.operationFailed(
                    "Transcription stopped in an invalid state."
                )
            }
        } catch is CancellationError {
            return
        } catch {
            updatePhase(.failed(error.localizedDescription), requestID: requestID)
        }
    }

    private func initialPhase(for episodeID: String) -> EpisodeTranscriptionRequestPhase {
        guard let engine = transcriptions.activeEngine(for: episodeID) else {
            return .downloading
        }
        return engine == .appleSpeech ? .transcribingAppleSpeech : .transcribingWhisper
    }

    private func failRequest(episode: EpisodeListItemSnapshot, message: String) {
        request = EpisodeTranscriptionRequest(
            episodeID: episode.episodeID,
            episodeTitle: episode.title,
            phase: .failed(message)
        )
        isPresented = true
    }

    private func ensureCurrentRequest(id: UUID) throws {
        try Task.checkCancellation()
        guard activeRequestID == id else {
            throw CancellationError()
        }
    }

    private func updatePhase(_ phase: EpisodeTranscriptionRequestPhase, requestID: UUID) {
        guard activeRequestID == requestID,
              var request,
              request.id == requestID
        else {
            return
        }
        request.phase = phase
        self.request = request
        onPhaseChange?(phase)
    }

    private func updateInterruptedPhase(episodeID: String, requestID: UUID) {
        guard activeRequestID == requestID,
              var request,
              request.id == requestID
        else {
            return
        }
        request.canResumeFromCheckpoint = transcriptions.hasResumableWhisperCheckpoint(
            for: episodeID
        )
        request.phase = .interrupted
        self.request = request
        onPhaseChange?(.interrupted)
    }
}
