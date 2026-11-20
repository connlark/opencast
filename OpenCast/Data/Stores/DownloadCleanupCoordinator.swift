import Foundation
import OpenCastPlayback
import SwiftData

/// Every deletion goes through the transcription store's deletion hook, so a transcript never
/// outlives its audio without knowing.
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

    /// The sweep's file I/O and saves must not land in the tap-to-audio turn; one main-actor turn
    /// later is soon enough.
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
        let eligibleRecords = downloads.records.filter {
            isRemovablePlayedDownload($0, remoteJobEpisodeIDs: remoteJobEpisodeIDs)
        }
        deleteDownloads(eligibleRecords, modelContext: modelContext)
    }

    /// Reads only observable state, so a view's count follows protection as it changes.
    func removablePlayedDownloadCount() -> Int {
        let remoteJobEpisodeIDs = remoteJobEpisodeIDs()
        return downloads.records.count {
            isRemovablePlayedDownload($0, remoteJobEpisodeIDs: remoteJobEpisodeIDs)
        }
    }

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
        let sparesTranscriptAudio = !settings.detectsAdsInNewEpisodes(forPodcastID: podcastID)
        let excessRecords = completedRecords
            .sorted(by: Self.isMoreRecentlyCompleted)
            .dropFirst(maximumCount)
            .filter {
                !(isInUse($0, remoteJobEpisodeIDs: remoteJobEpisodeIDs)
                    || (sparesTranscriptAudio && isUnheardTranscriptAsset($0)))
            }
        deleteDownloads(Array(excessRecords), modelContext: modelContext)
    }

    func trimAllDownloadsToKeepLimits(modelContext: ModelContext) {
        let podcastIDs = Set(downloads.records.lazy.filter { $0.state == .completed }.map(\.podcastID))
        for podcastID in podcastIDs.sorted() {
            trimDownloadsToKeepLimit(forPodcastID: podcastID, modelContext: modelContext)
        }
    }

    /// The trim's deletes and saves must run outside the download store's completion commit: one
    /// main-actor turn later, coalescing completions that land in the same turn.
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

    private func isRemovablePlayedDownload(
        _ record: EpisodeDownloadRecord,
        remoteJobEpisodeIDs: Set<String>
    ) -> Bool {
        record.state == .completed
            && library.progressRecord(for: record.episodeID)?.isPlayed == true
            && !isInUse(record, remoteJobEpisodeIDs: remoteJobEpisodeIDs)
    }

    private func isInUse(
        _ record: EpisodeDownloadRecord,
        remoteJobEpisodeIDs: Set<String>
    ) -> Bool {
        if playback.currentEpisode?.id.rawValue == record.episodeID
            || transcriptions.isActivelyTranscribing(episodeID: record.episodeID)
            || transcriptions.holdsWorkReservation(forEpisodeID: record.episodeID)
            || remoteJobEpisodeIDs.contains(record.episodeID) {
            return true
        }

        switch adFreePass.queueStatus(for: record.episodeID) {
        case .queued, .running, .remoteParked:
            return true
        case .notQueued, .completed, .failed, .cloudUnavailable, .keyRequired:
            return false
        }
    }

    private func isUnheardTranscriptAsset(_ record: EpisodeDownloadRecord) -> Bool {
        TranscriptSourceAlignment.downloadMatchesTranscript(
            trustedDownloadSHA256: record.sourceFileSHA256,
            documentSHA256: transcriptions.record(for: record.episodeID)?.sourceFileSHA256 ?? ""
        ) && library.progressRecord(for: record.episodeID)?.isPlayed != true
    }

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
