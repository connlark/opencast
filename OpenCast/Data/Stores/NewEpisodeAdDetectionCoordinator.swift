import Foundation
import SwiftData

/// While no marker is pending, a completion and a sweep return before any other read.
final class NewEpisodeAdDetectionCoordinator {
    struct EnqueueRequest: Equatable {
        let episode: EpisodeListItemSnapshot
        let origin: AdFreePassQueueOrigin
        let mode: AdDetectionMode
        let presentsKeyScreen: Bool
    }

    private let settings: DownloadSettingsStore
    private let downloadRecord: (String) -> EpisodeDownloadRecord?
    private let hasDownloadedFile: (EpisodeDownloadRecord) -> Bool
    private let resolveEpisode: (String) -> EpisodeListItemSnapshot?
    private let releasedEpisodes: (String) -> [EpisodeListItemSnapshot]
    private let isPlayedOrArchived: (String) -> Bool
    private let queueStatus: (String) -> AdFreePassQueueEpisodeStatus
    private let isQueueRestored: () -> Bool
    private let enqueue: (EnqueueRequest, ModelContext) -> Void

    /// `releasedEpisodes` is newest first. Markers wait for `isQueueRestored`, so an item the
    /// launch restore brings back is never queued twice.
    init(
        settings: DownloadSettingsStore,
        downloadRecord: @escaping (String) -> EpisodeDownloadRecord?,
        hasDownloadedFile: @escaping (EpisodeDownloadRecord) -> Bool,
        episode: @escaping (String) -> EpisodeListItemSnapshot?,
        releasedEpisodes: @escaping (String) -> [EpisodeListItemSnapshot],
        isPlayedOrArchived: @escaping (String) -> Bool,
        queueStatus: @escaping (String) -> AdFreePassQueueEpisodeStatus,
        isQueueRestored: @escaping () -> Bool,
        enqueue: @escaping (EnqueueRequest, ModelContext) -> Void
    ) {
        self.settings = settings
        self.downloadRecord = downloadRecord
        self.hasDownloadedFile = hasDownloadedFile
        self.resolveEpisode = episode
        self.releasedEpisodes = releasedEpisodes
        self.isPlayedOrArchived = isPlayedOrArchived
        self.queueStatus = queueStatus
        self.isQueueRestored = isQueueRestored
        self.enqueue = enqueue
    }

    /// Queues in this turn, so the queue entry protects the download before the Keep Downloaded
    /// trim runs.
    func downloadCompleted(episodeID: String, modelContext: ModelContext) {
        guard let podcastID = settings.detectAdsPendingPodcastID(forEpisodeID: episodeID),
              isQueueRestored()
        else {
            return
        }

        take([(episodeID, podcastID)], removingMarkersFor: [episodeID], modelContext: modelContext)
    }

    func sweep(modelContext: ModelContext) {
        let markers = settings.detectAdsPendingPodcastIDsByEpisodeID
        guard !markers.isEmpty, isQueueRestored() else {
            return
        }

        var taken: [(episodeID: String, podcastID: String)] = []
        var removed: [String] = []
        for (episodeID, podcastID) in markers.sorted(by: { $0.key < $1.key }) {
            // A marker outlives its show's setting only as a row the
            // settings store had not loaded when the setting went off.
            guard settings.detectsAdsInNewEpisodes(forPodcastID: podcastID),
                  let record = downloadRecord(episodeID)
            else {
                removed.append(episodeID)
                continue
            }
            if record.state == .completed, hasDownloadedFile(record) {
                taken.append((episodeID, podcastID))
                removed.append(episodeID)
            }
        }
        take(taken, removingMarkersFor: removed, modelContext: modelContext)
    }

    /// Call after the show's flag is saved: the sweep drops the markers of a show without it.
    func enable(forPodcastID podcastID: String, modelContext: ModelContext) {
        let released = releasedEpisodes(podcastID)
        if let newestReleaseDate = released.first?.publishedAt {
            var markers: [String: String] = [:]
            for episode in released.prefix(while: { $0.publishedAt == newestReleaseDate })
            where downloadRecord(episode.episodeID) != nil {
                markers[episode.episodeID] = podcastID
            }
            settings.addDetectAdsPendingMarkers(markers, modelContext: modelContext)
        }
        sweep(modelContext: modelContext)
    }

    /// Markers are removed first, so a marker whose removal could not be
    /// saved is not taken now and stays for a later sweep.
    private func take(
        _ markers: [(episodeID: String, podcastID: String)],
        removingMarkersFor removedEpisodeIDs: [String],
        modelContext: ModelContext
    ) {
        guard settings.removeDetectAdsPendingMarkers(forEpisodeIDs: removedEpisodeIDs, modelContext: modelContext) else {
            return
        }

        for marker in markers {
            guard settings.detectsAdsInNewEpisodes(forPodcastID: marker.podcastID),
                  let episode = resolveEpisode(marker.episodeID),
                  !isPlayedOrArchived(marker.episodeID),
                  !Self.isQueuedOrRunning(queueStatus(marker.episodeID))
            else {
                continue
            }

            enqueue(
                EnqueueRequest(episode: episode, origin: .prepared, mode: .onDevice, presentsKeyScreen: false),
                modelContext
            )
        }
    }

    private static func isQueuedOrRunning(_ status: AdFreePassQueueEpisodeStatus) -> Bool {
        switch status {
        case .queued, .running, .remoteParked:
            true
        case .notQueued, .completed, .failed, .cloudUnavailable, .keyRequired:
            false
        }
    }
}
