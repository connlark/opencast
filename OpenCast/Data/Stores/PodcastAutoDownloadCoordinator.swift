import Foundation
import SwiftData

final class PodcastAutoDownloadCoordinator {
    static let unlimitedBatchCap = 3

    private let library: LibraryStore
    private let downloads: DownloadStore
    private let settings: DownloadSettingsStore
    private let currentNetworkPath: () async -> NetworkPathSnapshot
    private let now: () -> Date
    private var passTask: Task<Void, Never>?
    private var passGeneration = 0
    private var rerunRequested = false
    // Live per-scene activity: a caller deciding across awaits whether its scene is active can act
    // on a stale answer. Passes run while any scene is active.
    private var sceneActivity: [UUID: Bool] = [:]
    private var hasRegisteredScene = false

    init(
        library: LibraryStore,
        downloads: DownloadStore,
        settings: DownloadSettingsStore,
        currentNetworkPath: @escaping () async -> NetworkPathSnapshot = NetworkPathObserver.currentPath,
        now: @escaping () -> Date = { .now }
    ) {
        self.library = library
        self.downloads = downloads
        self.settings = settings
        self.currentNetworkPath = currentNetworkPath
        self.now = now
    }

    @discardableResult
    func enableAutoDownload(forPodcastID podcastID: String, modelContext: ModelContext) -> Bool {
        guard !settings.autoDownloadsNewEpisodes(forPodcastID: podcastID) else {
            return true
        }
        guard settings.setAutoDownloadsNewEpisodes(
            true,
            forPodcastID: podcastID,
            watermark: initialWatermark(forPodcastID: podcastID),
            modelContext: modelContext
        ) else {
            return false
        }

        schedulePass(modelContext: modelContext)
        return true
    }

    func schedulePass(modelContext: ModelContext) {
        guard isForeground else {
            return
        }
        guard passTask == nil else {
            rerunRequested = true
            return
        }

        passGeneration += 1
        let generation = passGeneration
        passTask = Task { [weak self] in
            await self?.runScheduledPasses(generation: generation, modelContext: modelContext)
            guard let self, passGeneration == generation else {
                return
            }
            passTask = nil
        }
    }

    func runPass(modelContext: ModelContext) async {
        schedulePass(modelContext: modelContext)
        await passTask?.value
    }

    var isForeground: Bool {
        hasRegisteredScene ? sceneActivity.values.contains(true) : true
    }

    func setScene(_ sceneID: UUID, isActive: Bool) {
        let wasForeground = isForeground
        hasRegisteredScene = true
        sceneActivity[sceneID] = isActive
        suspendIfLeftForeground(wasForeground)
    }

    func removeScene(_ sceneID: UUID) {
        let wasForeground = isForeground
        sceneActivity[sceneID] = nil
        suspendIfLeftForeground(wasForeground)
    }

    private func suspendIfLeftForeground(_ wasForeground: Bool) {
        if wasForeground, !isForeground {
            cancelPendingWork()
        }
    }

    /// A pass cancelled at its network check leaves every watermark in place, so the next pass
    /// picks the same episodes up.
    func cancelPendingWork() {
        passGeneration += 1
        passTask?.cancel()
        passTask = nil
        rerunRequested = false
    }

    /// A cancelled or superseded pass stops before touching the shared
    /// rerun flag, a watermark or a download.
    private func runScheduledPasses(generation: Int, modelContext: ModelContext) async {
        while isCurrent(generation) {
            rerunRequested = false
            await runPassOnce(generation: generation, modelContext: modelContext)
            guard rerunRequested else {
                return
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && passGeneration == generation
    }

    private func runPassOnce(generation: Int, modelContext: ModelContext) async {
        var hasCandidates = false
        let asOf = now()
        for podcastID in enabledPodcastIDs() {
            guard let watermark = settings.autoDownloadWatermark(forPodcastID: podcastID) else {
                // A missing watermark row heals at the newest release with
                // nothing downloaded.
                if let newest = library.newestReleasedEpisode(forPodcastID: podcastID, asOf: asOf)?.publishedAt {
                    settings.setAutoDownloadWatermark(newest, forPodcastID: podcastID, modelContext: modelContext)
                }
                continue
            }
            let released = library.releasedEpisodes(forPodcastID: podcastID, publishedAfter: watermark, asOf: asOf)
            if candidates(in: released).isEmpty {
                // Releases already downloaded by hand still move the
                // watermark, so deleting one later can't bring it back.
                advanceWatermark(forPodcastID: podcastID, past: released, modelContext: modelContext)
            } else {
                hasCandidates = true
            }
        }
        guard hasCandidates else {
            return
        }

        if settings.autoDownloadsRequireWiFi {
            let path = await currentNetworkPath()
            guard isCurrent(generation), path.allowsAutomaticDownloads else {
                return
            }
        }

        // Settings, the library and download records may have moved during
        // the network check; everything below is recomputed and runs in one
        // synchronous stretch, so each watermark moves with its starts.
        let startAsOf = now()
        var detectAdsPodcastIDsByEpisodeID: [String: String] = [:]
        for podcastID in enabledPodcastIDs() {
            guard let watermark = settings.autoDownloadWatermark(forPodcastID: podcastID) else {
                continue
            }
            let released = library.releasedEpisodes(forPodcastID: podcastID, publishedAfter: watermark, asOf: startAsOf)
            let batchCap = settings.resolvedKeepLimit(forPodcastID: podcastID).maximumCount ?? Self.unlimitedBatchCap
            let detectsAds = settings.detectsAdsInNewEpisodes(forPodcastID: podcastID)
            for episode in candidates(in: released).prefix(batchCap) {
                // A false leaves a failed record and the store's error
                // message; the record keeps later passes from retrying.
                if downloads.startDownload(for: episode, modelContext: modelContext), detectsAds {
                    detectAdsPodcastIDsByEpisodeID[episode.episodeID] = podcastID
                }
            }
            advanceWatermark(forPodcastID: podcastID, past: released, modelContext: modelContext)
        }
        // A completion lands in a later turn, so each marker is in place
        // before its download can finish.
        settings.addDetectAdsPendingMarkers(detectAdsPodcastIDsByEpisodeID, modelContext: modelContext)
    }

    private func enabledPodcastIDs() -> [String] {
        settings.autoDownloadPodcastIDs.intersection(library.activePodcastIDs).sorted()
    }

    private func candidates(in released: [EpisodeListItemSnapshot]) -> [EpisodeListItemSnapshot] {
        released.filter { $0.audioURL != nil && downloads.record(for: $0.episodeID) == nil }
    }

    private func advanceWatermark(
        forPodcastID podcastID: String,
        past released: [EpisodeListItemSnapshot],
        modelContext: ModelContext
    ) {
        guard let newest = released.first?.publishedAt else {
            return
        }
        settings.setAutoDownloadWatermark(newest, forPodcastID: podcastID, modelContext: modelContext)
    }

    /// The newest release date strictly older than the newest release, so
    /// every episode sharing the newest timestamp is a candidate.
    private func initialWatermark(forPodcastID podcastID: String) -> Date {
        let asOf = now()
        guard let newest = library.newestReleasedEpisode(forPodcastID: podcastID, asOf: asOf)?.publishedAt else {
            return .distantPast
        }
        return library.releasedEpisodes(forPodcastID: podcastID, publishedAfter: .distantPast, asOf: asOf)
            .lazy
            .compactMap(\.publishedAt)
            .first { $0 < newest } ?? .distantPast
    }
}
