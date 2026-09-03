import Foundation
import OpenCastPlayback
import SwiftData

/// Download deletion and the played-download sweep, always routed through
/// the transcription store's deletion hook so a transcript never outlives
/// the audio it describes without knowing.
final class DownloadCleanupCoordinator {
    private let downloads: DownloadStore
    private let transcriptions: EpisodeTranscriptionStore
    private let library: LibraryStore
    private let playback: AVFoundationPlaybackController
    private let adFreePass: EpisodeAdFreePassCoordinator
    private var deferredPlayedSweepTask: Task<Void, Never>?

    init(
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        library: LibraryStore,
        playback: AVFoundationPlaybackController,
        adFreePass: EpisodeAdFreePassCoordinator
    ) {
        self.downloads = downloads
        self.transcriptions = transcriptions
        self.library = library
        self.playback = playback
        self.adFreePass = adFreePass
    }

    func deleteDownload(_ record: EpisodeDownloadRecord, modelContext: ModelContext) {
        let localFileURL = downloads.localFileURL(for: record)
        transcriptions.handleDownloadDeletion(record, localFileURL: localFileURL, modelContext: modelContext)
        downloads.deleteDownload(record, modelContext: modelContext)
    }

    func deleteDownloads(_ records: [EpisodeDownloadRecord], modelContext: ModelContext) {
        handleTranscriptionCleanup(forDeletedDownloads: records, modelContext: modelContext)
        downloads.deleteDownloads(records, modelContext: modelContext)
    }

    func deleteAllDownloads(modelContext: ModelContext) {
        transcriptions.handleAllDownloadsDeleted(modelContext: modelContext)
        downloads.deleteAllDownloads(modelContext: modelContext)
    }

    func deleteCompletedDownloads(forPodcastID podcastID: String, modelContext: ModelContext) throws {
        let completedRecords = downloads.records.filter {
            $0.podcastID == podcastID && $0.state == .completed
        }
        handleTranscriptionCleanup(forDeletedDownloads: completedRecords, modelContext: modelContext)
        try downloads.deleteDownloadsThrowing(completedRecords, modelContext: modelContext)
    }

    func deleteDownloads(forPodcastID podcastID: String, modelContext: ModelContext) throws {
        let records = downloads.records.filter { $0.podcastID == podcastID }
        handleTranscriptionCleanup(forDeletedDownloads: records, modelContext: modelContext)
        try downloads.deleteDownloads(forPodcastID: podcastID, modelContext: modelContext)
    }

    func sweepPlayedDownloadsIfEnabled(modelContext: ModelContext) {
        guard downloads.autoDeletesPlayedDownloads else {
            return
        }

        deletePlayedDownloads(modelContext: modelContext)
    }

    /// The sweep's file I/O and saves must not land in the tap-to-audio
    /// turn; one main-actor turn later is soon enough (same shape as
    /// the app model's deferred playback teardown).
    func deferPlayedSweep(modelContext: ModelContext) {
        guard deferredPlayedSweepTask == nil else {
            return
        }

        deferredPlayedSweepTask = Task { [weak self] in
            guard let self else {
                return
            }
            deferredPlayedSweepTask = nil
            sweepPlayedDownloadsIfEnabled(modelContext: modelContext)
        }
    }

    func deletePlayedDownloads(modelContext: ModelContext) {
        let eligibleRecords = downloads.records.filter { record in
            guard record.state == .completed else {
                return false
            }
            guard library.progressRecord(for: record.episodeID)?.isPlayed == true,
                  playback.currentEpisode?.id.rawValue != record.episodeID,
                  !transcriptions.isActivelyTranscribing(episodeID: record.episodeID)
            else {
                return false
            }
            // A download whose bytes a transcript describes is that
            // transcript's karaoke asset; sweeping it would strand the
            // transcript on a mismatch no re-download can repair (dynamic
            // enclosures return different assemblies).
            if TranscriptSourceAlignment.downloadMatchesTranscript(
                trustedDownloadSHA256: record.sourceFileSHA256,
                documentSHA256: transcriptions.record(for: record.episodeID)?.sourceFileSHA256 ?? ""
            ) {
                return false
            }

            switch adFreePass.queueStatus(for: record.episodeID) {
            case .queued, .running, .capDeferred:
                return false
            case .notQueued, .completed, .failed, .cloudUnavailable:
                return true
            }
        }
        deleteDownloads(eligibleRecords, modelContext: modelContext)
    }

    private func handleTranscriptionCleanup(
        forDeletedDownloads records: [EpisodeDownloadRecord],
        modelContext: ModelContext
    ) {
        for record in records {
            let localFileURL = downloads.localFileURL(for: record)
            transcriptions.handleDownloadDeletion(
                record,
                localFileURL: localFileURL,
                modelContext: modelContext
            )
        }
    }
}
