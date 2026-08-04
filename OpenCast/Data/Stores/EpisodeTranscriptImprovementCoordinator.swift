import Foundation
import Observation
import SwiftData

/// Drives the explicit "Improve Transcript" flow: an Apple Speech
/// re-transcription of an episode that already has a completed Whisper
/// transcript. Foreground-only by design — no background session is armed, so
/// the existing lifecycle policy interrupts the run on backgrounding and the
/// store's prior-transcript snapshot puts the Whisper transcript back.
@Observable
final class EpisodeTranscriptImprovementCoordinator {
    enum Phase: Equatable {
        case idle
        case installingAssets
        case transcribing
        case completed
        case interrupted
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .completed, .interrupted, .failed:
                true
            case .idle, .installingAssets, .transcribing:
                false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var episodeID: String?

    private let appleSpeechAssets: AppleSpeechAssetStore
    private let transcriptions: EpisodeTranscriptionStore
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var activeRunID: UUID?

    init(
        appleSpeechAssets: AppleSpeechAssetStore,
        transcriptions: EpisodeTranscriptionStore
    ) {
        self.appleSpeechAssets = appleSpeechAssets
        self.transcriptions = transcriptions
    }

    var isRunning: Bool {
        phase == .installingAssets || phase == .transcribing
    }

    func start(
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        podcastLanguageCode: String?,
        modelContext: ModelContext
    ) {
        guard runTask == nil,
              phase == .idle || phase.isTerminal,
              transcriptions.record(for: episode.episodeID)?.state == .completed,
              FileManager.default.fileExists(atPath: localFileURL.path),
              appleSpeechAssets.isTranscriberAvailable
        else {
            return
        }

        let localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation
        switch transcriptions.reserveLocalWork(for: episode.episodeID) {
        case .success(let value):
            localReservation = value
        case .failure(let conflict):
            self.episodeID = episode.episodeID
            phase = .failed(conflict.localizedDescription)
            return
        }

        let runID = UUID()
        episodeID = episode.episodeID
        phase = .installingAssets
        activeRunID = runID
        runTask = Task { [weak self] in
            await self?.run(
                runID: runID,
                episode: episode,
                downloadRecord: downloadRecord,
                localFileURL: localFileURL,
                podcastLanguageCode: podcastLanguageCode,
                localReservation: localReservation,
                modelContext: modelContext
            )
        }
    }

    /// "Stop" keeps the current transcript: the store restores the preserved
    /// Whisper record and the banner disappears immediately.
    func cancel(modelContext: ModelContext) {
        guard isRunning else {
            return
        }

        if let episodeID {
            transcriptions.cancelTranscription(episodeID: episodeID, modelContext: modelContext)
        }
        runTask?.cancel()
        activeRunID = nil
        phase = .idle
        episodeID = nil
    }

    func acknowledgeTerminal() {
        guard phase.isTerminal else {
            return
        }

        phase = .idle
        episodeID = nil
    }

    func resetForDataNuke() {
        let task = runTask
        runTask = nil
        activeRunID = nil
        phase = .idle
        episodeID = nil
        task?.cancel()
    }

    private func run(
        runID: UUID,
        episode: EpisodeListItemSnapshot,
        downloadRecord: EpisodeDownloadRecord,
        localFileURL: URL,
        podcastLanguageCode: String?,
        localReservation: EpisodeTranscriptionWorkCoordinator.LocalReservation,
        modelContext: ModelContext
    ) async {
        defer {
            transcriptions.releaseLocalWork(localReservation)
            if activeRunID == runID {
                activeRunID = nil
                runTask = nil
            }
        }

        do {
            let languageCode = podcastLanguageCode ?? EpisodeTranscriptionPlanResolver.fallbackLanguageCode
            let localeIdentifier = try await appleSpeechAssets.ensureInstalledAssets(
                forLanguageCode: languageCode
            )
            try Task.checkCancellation()
            let identity = EpisodeTranscriptionPlanResolver.appleModelIdentity(
                localeIdentifier: localeIdentifier
            )

            updatePhase(.transcribing, runID: runID)
            guard transcriptions.startTranscription(
                episode,
                downloadRecord: downloadRecord,
                localFileURL: localFileURL,
                engine: .appleSpeech,
                modelIdentity: identity,
                languageCode: languageCode,
                preservesPriorCompletedTranscript: true,
                localReservation: localReservation,
                modelContext: modelContext
            ) else {
                throw EpisodeTranscriptionRequestError.operationFailed(
                    transcriptions.lastErrorMessage(for: episode.episodeID)
                        ?? "Unable to start the improved transcription."
                )
            }

            while transcriptions.isActivelyTranscribing(episodeID: episode.episodeID) {
                let sequence = transcriptions.changeSequence
                try await transcriptions.waitForChange(after: sequence)
            }
            try Task.checkCancellation()
            updatePhase(
                outcome(episodeID: episode.episodeID, appleIdentity: identity),
                runID: runID
            )
        } catch is CancellationError {
            return
        } catch {
            updatePhase(.failed(error.localizedDescription), runID: runID)
        }
    }

    private func outcome(
        episodeID: String,
        appleIdentity: EpisodeTranscriptionModelIdentity
    ) -> Phase {
        guard let record = transcriptions.record(for: episodeID) else {
            return .failed("The transcript was deleted while improving.")
        }
        if record.state == .completed, record.modelIdentifier == appleIdentity.modelIdentifier {
            return .completed
        }
        if let message = transcriptions.lastErrorMessage(for: episodeID) {
            return .failed(message)
        }
        return .interrupted
    }

    private func updatePhase(_ newPhase: Phase, runID: UUID) {
        guard activeRunID == runID else {
            return
        }
        phase = newPhase
    }
}
