import Foundation
import OpenCastPlayback
import SwiftData

/// Download deletion, the played-download sweep and the Keep Downloaded
/// trim, always routed through the transcription store's deletion hook so a
/// transcript never outlives the audio it describes without knowing.
final class DownloadCleanupCoordinator {
    private let downloads: DownloadStore
    private let transcriptions: EpisodeTranscriptionStore
    private let library: LibraryStore
    private let playback: AVFoundationPlaybackController
    private let adFreePass: EpisodeAdFreePassCoordinator
    private let settings: DownloadSettingsStore
    private let remoteJobEpisodeIDs: () -> Set<String>
    private var deferredPlayedSweepTask: Task<Void, Never>?
    private var deferredTrimTask: Task<Void, Never>?
    private var pendingTrimPodcastIDs: Set<String> = []

    init(
        downloads: DownloadStore,
        transcriptions: EpisodeTranscriptionStore,
        library: LibraryStore,
        playback: AVFoundationPlaybackController,
        adFreePass: EpisodeAdFreePassCoordinator,
        settings: DownloadSettingsStore,
        remoteJobEpisodeIDs: @escaping () -> Set<String> = { [] }
    ) {
        self.downloads = downloads
        self.transcriptions = transcriptions
        self.library = library
        self.playback = playback
        self.adFreePass = adFreePass
        self.settings = settings
        self.remoteJobEpisodeIDs = remoteJobEpisodeIDs
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
        let remoteJobEpisodeIDs = remoteJobEpisodeIDs()
        let eligibleRecords = downloads.records.filter { record in
            record.state == .completed
                && library.progressRecord(for: record.episodeID)?.isPlayed == true
                && !isProtectedFromAutomaticDeletion(record, remoteJobEpisodeIDs: remoteJobEpisodeIDs)
        }
        deleteDownloads(eligibleRecords, modelContext: modelContext)
    }

    /// Keeps the show's most recently completed downloads up to its Keep
    /// Downloaded limit and deletes the rest. A protected download is never
    /// deleted but still holds its place, so a show can sit above its limit
    /// while one is in use. Played state is irrelevant.
    func trimDownloadsToKeepLimit(forPodcastID podcastID: String, modelContext: ModelContext) {
        guard let maximumCount = settings.resolvedKeepLimit(forPodcastID: podcastID).maximumCount else {
            return
        }

        let completedRecords = downloads.records.filter {
            $0.podcastID == podcastID && $0.state == .completed
        }
        guard completedRecords.count > maximumCount else {
            return
        }

        let remoteJobEpisodeIDs = remoteJobEpisodeIDs()
        let excessRecords = completedRecords
            .sorted(by: Self.isMoreRecentlyCompleted)
            .dropFirst(maximumCount)
            .filter { !isProtectedFromAutomaticDeletion($0, remoteJobEpisodeIDs: remoteJobEpisodeIDs) }
        deleteDownloads(Array(excessRecords), modelContext: modelContext)
    }

    func trimAllDownloadsToKeepLimits(modelContext: ModelContext) {
        let podcastIDs = Set(downloads.records.lazy.filter { $0.state == .completed }.map(\.podcastID))
        for podcastID in podcastIDs.sorted() {
            trimDownloadsToKeepLimit(forPodcastID: podcastID, modelContext: modelContext)
        }
    }

    /// A completion commits inside the download store; the trim's deletes
    /// and saves run one main-actor turn later, outside that commit, and
    /// completions landing in the same turn coalesce.
    func deferTrim(forPodcastID podcastID: String, modelContext: ModelContext) {
        pendingTrimPodcastIDs.insert(podcastID)
        guard deferredTrimTask == nil else {
            return
        }

        deferredTrimTask = Task { [weak self] in
            guard let self else {
                return
            }
            deferredTrimTask = nil
            let podcastIDs = pendingTrimPodcastIDs
            pendingTrimPodcastIDs.removeAll()
            for podcastID in podcastIDs.sorted() {
                trimDownloadsToKeepLimit(forPodcastID: podcastID, modelContext: modelContext)
            }
        }
    }

    /// Downloads in use survive every automatic deletion: the episode
    /// that's playing, one a transcription request holds (local or remote,
    /// from its preparation on), one with a remote job that may still ask
    /// for an exact-copy upload, one whose bytes a transcript describes,
    /// and one an ad-free pass is waiting on or running.
    private func isProtectedFromAutomaticDeletion(
        _ record: EpisodeDownloadRecord,
        remoteJobEpisodeIDs: Set<String>
    ) -> Bool {
        guard playback.currentEpisode?.id.rawValue != record.episodeID,
              !transcriptions.isActivelyTranscribing(episodeID: record.episodeID),
              !transcriptions.workCoordinator.holdsReservation(forEpisodeID: record.episodeID),
              !remoteJobEpisodeIDs.contains(record.episodeID)
        else {
            return true
        }
        // A download whose bytes a transcript describes is that
        // transcript's karaoke asset; deleting it would strand the
        // transcript on a mismatch no re-download can repair (dynamic
        // enclosures return different assemblies).
        if TranscriptSourceAlignment.downloadMatchesTranscript(
            trustedDownloadSHA256: record.sourceFileSHA256,
            documentSHA256: transcriptions.record(for: record.episodeID)?.sourceFileSHA256 ?? ""
        ) {
            return true
        }

        switch adFreePass.queueStatus(for: record.episodeID) {
        case .queued, .running, .remoteParked:
            return true
        case .notQueued, .completed, .failed, .cloudUnavailable, .keyRequired:
            return false
        }
    }

    /// Newest completion first. Records completed before `completedAt`
    /// existed fall back to when the episode was first requested; ties go
    /// to the newer episode, then the episode ID.
    private static func isMoreRecentlyCompleted(_ lhs: EpisodeDownloadRecord, _ rhs: EpisodeDownloadRecord) -> Bool {
        let lhsCompletedAt = lhs.completedAt ?? lhs.createdAt
        let rhsCompletedAt = rhs.completedAt ?? rhs.createdAt
        if lhsCompletedAt != rhsCompletedAt {
            return lhsCompletedAt > rhsCompletedAt
        }
        let lhsPublishedAt = lhs.publishedAt ?? .distantPast
        let rhsPublishedAt = rhs.publishedAt ?? .distantPast
        if lhsPublishedAt != rhsPublishedAt {
            return lhsPublishedAt > rhsPublishedAt
        }
        return lhs.episodeID < rhs.episodeID
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
