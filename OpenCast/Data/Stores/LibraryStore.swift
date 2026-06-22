import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class LibraryStore {
    static let refreshLogRetentionLimit = 50
    static let completedEpisodeRemainingThreshold: TimeInterval = 60
    static let foregroundRefreshInterval: TimeInterval = 60 * 60

    enum State: Equatable {
        case idle
        case loading
        case refreshing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var subscriptions: [SubscriptionRecord] = []
    private(set) var episodes: [EpisodeListItemSnapshot] = []
    private(set) var progressRecords: [EpisodeProgressRecord] = []
    private(set) var refreshLogs: [RefreshLogSnapshot] = []
    private(set) var refreshingFeedURLs: Set<String> = []
    private(set) var activePodcastIDs: Set<String> = []
    private(set) var visibleEpisodeIDs: Set<String> = []
    private(set) var podcastCacheByFeedURL: [String: PodcastCacheSnapshot] = [:]
    private(set) var latestRefreshLogByFeedURL: [String: RefreshLogSnapshot] = [:]
    private(set) var lastErrorMessage: String?
    private(set) var subscriptionAddedToken = 0
    private(set) var refreshCompletedToken = 0

    @ObservationIgnored private let feedService: any FeedService
    @ObservationIgnored private let localCache: any LocalLibraryCacheStore
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var episodeIndexByID: [String: Int] = [:]
    @ObservationIgnored private var episodeIndicesByPodcastID: [String: [Int]] = [:]
    // Observable (not @ObservationIgnored): progressSummary reads only this
    // dictionary, so rows must establish their progress dependency through it.
    private var progressByEpisodeID: [String: EpisodeProgressRecord] = [:]
    @ObservationIgnored private var pendingCacheWriteTask: Task<Void, Never>?

    init(
        feedService: any FeedService = DefaultFeedService(),
        localCache: any LocalLibraryCacheStore
    ) {
        self.feedService = feedService
        self.localCache = localCache
    }

    /// The episode list is already filtered to active subscriptions and ordered
    /// newest-first by the cache store, so the inbox is the same list.
    var inboxEpisodes: [EpisodeListItemSnapshot] {
        episodes
    }

    var latestRefreshOverall: RefreshLogSnapshot? {
        refreshLogs.first
    }

    var latestRefreshFailure: RefreshLogSnapshot? {
        refreshLogs.first { log in
            guard let errorMessage = log.errorMessage else {
                return false
            }
            return !errorMessage.isEmpty
        }
    }

    var refreshLogCount: Int {
        refreshLogs.count
    }

    var feedURLStringsNeedingLocalCache: [String] {
        subscriptions.compactMap { subscription in
            let feedURL = subscription.feedURL
            let hasPodcastCache = podcastCacheByFeedURL[feedURL] != nil
            let hasEpisodeCache = !(episodeIndicesByPodcastID[feedURL]?.isEmpty ?? true)
            return hasPodcastCache && hasEpisodeCache ? nil : feedURL
        }
    }

    func load(modelContext: ModelContext) async {
        state = .loading
        lastErrorMessage = nil
        await importLegacyCacheIfNeeded(modelContext: modelContext)
        do {
            try await reloadFromStore(modelContext: modelContext)
            state = .idle
        } catch {
            recordFailure(error)
        }
    }

    func reloadPersistedData(modelContext: ModelContext) async throws {
        do {
            try await reloadFromStore(modelContext: modelContext)
            if state == .loading {
                state = .idle
            }
            lastErrorMessage = nil
        } catch {
            recordFailure(error)
            throw error
        }
    }

    func reloadSyncedUserData(modelContext: ModelContext) throws -> SyncedUserDataReloadResult {
        do {
            let previousActivePodcastIDs = activePodcastIDs
            let previousSubscriptions = subscriptions
            let previousProgressRecords = progressRecords
            let fetchedSubscriptions = try modelContext.fetch(activeSubscriptionsDescriptor())
            let fetchedActivePodcastIDs = Set(fetchedSubscriptions.map(\.feedURL))
            let fetchedProgressRecords = sortedProgressRecords(
                try modelContext.fetch(allProgressRecordsDescriptor())
            )

            let activePodcastIDsChanged = previousActivePodcastIDs != fetchedActivePodcastIDs
            let activeSubscriptionRecordsChanged = !Self.subscriptionRecords(
                previousSubscriptions,
                match: fetchedSubscriptions
            )
            let progressRecordsChanged = !Self.progressRecords(
                previousProgressRecords,
                match: fetchedProgressRecords
            )

            if activeSubscriptionRecordsChanged {
                subscriptions = fetchedSubscriptions
            }
            if activePodcastIDsChanged {
                activePodcastIDs = fetchedActivePodcastIDs
                episodes = episodes.filter { fetchedActivePodcastIDs.contains($0.podcastID) }
                visibleEpisodeIDs = Set(episodes.map(\.episodeID))
                rebuildEpisodeIndexes()
            }
            if progressRecordsChanged {
                progressRecords = fetchedProgressRecords
                rebuildProgressByEpisodeID()
            }
            if activeSubscriptionRecordsChanged || progressRecordsChanged {
                lastErrorMessage = nil
            }

            return SyncedUserDataReloadResult(
                activePodcastIDsChanged: activePodcastIDsChanged,
                activeSubscriptionRecordsChanged: activeSubscriptionRecordsChanged,
                progressRecordsChanged: progressRecordsChanged
            )
        } catch {
            recordFailure(error)
            throw error
        }
    }

    func subscribe(
        to feedURLString: String,
        modelContext: ModelContext,
        reloadAfter: Bool = true
    ) async throws {
        let generation = writeGeneration
        guard let feedURL = URL(string: feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              feedURL.scheme != nil,
              feedURL.host != nil
        else {
            throw OpenCastCoreError.invalidFeedURL
        }

        if reloadAfter {
            state = .refreshing
            lastErrorMessage = nil
        }

        do {
            let snapshot = try await feedService.fetchFeed(at: feedURL)
            try ensureCurrentGeneration(generation)
            _ = try await upsert(snapshot: snapshot, modelContext: modelContext, subscribe: true)
            if reloadAfter {
                try await reloadFromStore(modelContext: modelContext)
                state = .idle
                subscriptionAddedToken += 1
            }
        } catch is CancellationError {
            if reloadAfter {
                state = .idle
            }
            throw CancellationError()
        } catch {
            if reloadAfter {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func refresh(feedURL: String, modelContext: ModelContext) async {
        let generation = writeGeneration
        lastErrorMessage = nil
        // Mark the feed busy before the first suspension so refreshAllIfStale
        // cannot start a duplicate refresh while the initial reload is in flight.
        refreshingFeedURLs.insert(feedURL)
        defer {
            refreshingFeedURLs.remove(feedURL)
        }
        do {
            try await reloadFromStore(modelContext: modelContext)
            guard let subscription = subscriptions.first(where: { $0.feedURL == feedURL }) else {
                if state != .refreshing {
                    state = .idle
                }
                return
            }

            try await refresh(subscription: subscription, generation: generation, modelContext: modelContext)
            try await reloadFromStore(modelContext: modelContext)
            if state != .refreshing {
                state = .idle
            }
        } catch is CancellationError {
            try? await reloadFromStore(modelContext: modelContext)
            if state != .refreshing {
                state = .idle
            }
        } catch {
            recordFailure(error)
        }
    }

    func refreshAll(modelContext: ModelContext) async {
        let generation = writeGeneration
        state = .refreshing
        lastErrorMessage = nil
        do {
            try await reloadFromStore(modelContext: modelContext)
            try await refreshAll(
                feedURLStrings: subscriptions.map(\.feedURL),
                generation: generation,
                modelContext: modelContext
            )
            try await reloadFromStore(modelContext: modelContext)
            state = .idle
            refreshCompletedToken += 1
        } catch is CancellationError {
            refreshingFeedURLs.removeAll()
            try? await reloadFromStore(modelContext: modelContext)
            state = .idle
        } catch {
            refreshingFeedURLs.removeAll()
            recordFailure(error)
        }
    }

    func refreshAllIfStale(modelContext: ModelContext, now: Date = .now) async {
        guard state != .refreshing, refreshingFeedURLs.isEmpty else {
            return
        }

        let staleFeedURLStrings = staleFeedURLStrings(now: now)
        guard !staleFeedURLStrings.isEmpty else {
            return
        }

        let generation = writeGeneration
        state = .refreshing
        lastErrorMessage = nil
        do {
            try await refreshAll(
                feedURLStrings: staleFeedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            try await reloadFromStore(modelContext: modelContext)
            state = .idle
        } catch is CancellationError {
            refreshingFeedURLs.removeAll()
            try? await reloadFromStore(modelContext: modelContext)
            state = .idle
        } catch {
            refreshingFeedURLs.removeAll()
            recordFailure(error)
        }
    }

    @discardableResult
    func refreshFeedsNeedingLocalCache(modelContext: ModelContext) async -> Bool {
        guard state != .refreshing, refreshingFeedURLs.isEmpty else {
            return false
        }

        let feedURLStrings = feedURLStringsNeedingLocalCache
        guard !feedURLStrings.isEmpty else {
            return false
        }

        let generation = writeGeneration
        state = .refreshing
        lastErrorMessage = nil
        do {
            try await refreshAll(
                feedURLStrings: feedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            try await reloadFromStore(modelContext: modelContext)
            state = .idle
            refreshCompletedToken += 1
            return true
        } catch is CancellationError {
            refreshingFeedURLs.removeAll()
            try? await reloadFromStore(modelContext: modelContext)
            state = .idle
            return false
        } catch {
            refreshingFeedURLs.removeAll()
            recordFailure(error)
            return false
        }
    }

    func unsubscribe(
        feedURL: String,
        modelContext: ModelContext,
        downloadStore: DownloadStore? = nil
    ) async {
        do {
            try downloadStore?.deleteDownloads(forPodcastID: feedURL, modelContext: modelContext)

            let targetFeedURL = feedURL
            let subscriptions = try modelContext.fetch(
                FetchDescriptor<SubscriptionRecord>(
                    predicate: #Predicate { record in
                        record.feedURL == targetFeedURL
                    }
                )
            )
            let progressRecords = try modelContext.fetch(
                FetchDescriptor<EpisodeProgressRecord>(
                    predicate: #Predicate { record in
                        record.podcastID == targetFeedURL
                    }
                )
            )
            // Legacy local cache rows linger only until the one-time SQLite
            // import has run; delete them so a later import cannot resurrect
            // this feed's cache.
            let legacyPodcastCaches = try modelContext.fetch(
                FetchDescriptor<PodcastCacheRecord>(
                    predicate: #Predicate { record in
                        record.feedURL == targetFeedURL
                    }
                )
            )
            let legacyEpisodeCaches = try modelContext.fetch(
                FetchDescriptor<EpisodeCacheRecord>(
                    predicate: #Predicate { record in
                        record.podcastID == targetFeedURL
                    }
                )
            )
            let legacyRefreshLogs = try modelContext.fetch(
                FetchDescriptor<RefreshLogRecord>(
                    predicate: #Predicate { record in
                        record.feedURL == targetFeedURL
                    }
                )
            )

            for record in subscriptions {
                modelContext.delete(record)
            }
            for record in progressRecords {
                modelContext.delete(record)
            }
            for record in legacyPodcastCaches {
                modelContext.delete(record)
            }
            for record in legacyEpisodeCaches {
                modelContext.delete(record)
            }
            for record in legacyRefreshLogs {
                modelContext.delete(record)
            }

            try modelContext.save()
            try await localCache.deleteCache(forPodcastID: feedURL)
            try await reloadFromStore(modelContext: modelContext)
            state = .idle
            lastErrorMessage = nil
        } catch {
            recordFailure(error)
        }
    }

    func clearLastError() {
        lastErrorMessage = nil
    }

    func refreshProgressRecords(modelContext: ModelContext) {
        do {
            try reloadProgressRecords(modelContext: modelContext)
        } catch {
            recordFailure(error)
        }
    }

    func repairSyncDuplicates(modelContext: ModelContext) async throws -> SyncRepairResult {
        let result = try SyncDuplicateRepairer.repair(modelContext: modelContext)
        if result.hasIssues {
            try await reloadFromStore(modelContext: modelContext)
        }
        state = .idle
        lastErrorMessage = nil
        return result
    }

    func prepareForDataNuke() {
        writeGeneration += 1
        reloadGeneration += 1
        refreshingFeedURLs.removeAll()
    }

    func deleteAllLocalCache() async throws {
        try await localCache.deleteAllLocalCache()
    }

    func resetAfterDataNuke() {
        reloadGeneration += 1
        state = .idle
        subscriptions.removeAll()
        episodes.removeAll()
        progressRecords.removeAll()
        refreshLogs.removeAll()
        refreshingFeedURLs.removeAll()
        activePodcastIDs.removeAll()
        visibleEpisodeIDs.removeAll()
        podcastCacheByFeedURL.removeAll()
        latestRefreshLogByFeedURL.removeAll()
        episodeIndexByID.removeAll()
        episodeIndicesByPodcastID.removeAll()
        progressByEpisodeID.removeAll()
        lastErrorMessage = nil
    }

    func episode(with id: String) -> EpisodeListItemSnapshot? {
        episodeIndexByID[id].map { episodes[$0] }
    }

    func episodes(forPodcastID podcastID: String) -> [EpisodeListItemSnapshot] {
        guard let indices = episodeIndicesByPodcastID[podcastID] else {
            return []
        }

        return indices.map { episodes[$0] }
    }

    func episodeDetail(for episodeID: String) async -> EpisodeDetailSnapshot? {
        do {
            return try await localCache.episodeDetail(episodeID: episodeID)
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Full-text search support: show notes are not part of list snapshots, so
    /// search fetches them on demand, scoped to one feed or all active feeds.
    /// Returns nil on a store failure so callers can avoid caching the miss.
    func showNotesHTMLByEpisodeID(forPodcastID podcastID: String? = nil) async -> [String: String]? {
        let scopedPodcastIDs: Set<String>
        if let podcastID {
            scopedPodcastIDs = activePodcastIDs.contains(podcastID) ? [podcastID] : []
        } else {
            scopedPodcastIDs = activePodcastIDs
        }

        do {
            return try await localCache.showNotesHTMLByEpisodeID(activePodcastIDs: scopedPodcastIDs)
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    func podcastCache(for feedURL: String) -> PodcastCacheSnapshot? {
        podcastCacheByFeedURL[feedURL]
    }

    func isActivelySubscribed(to feedURL: String) -> Bool {
        activePodcastIDs.contains(feedURL)
    }

    func isRefreshing(feedURL: String) -> Bool {
        refreshingFeedURLs.contains(feedURL)
    }

    func latestRefreshLog(feedURL: String) -> RefreshLogSnapshot? {
        latestRefreshLogByFeedURL[feedURL]
    }

    func domainEpisode(for episode: EpisodeListItemSnapshot) -> Episode {
        Episode(
            id: EpisodeID(rawValue: episode.episodeID),
            podcastID: PodcastID(rawValue: episode.podcastID),
            podcastTitle: episode.podcastTitle,
            title: episode.title,
            summary: episode.summary,
            // Show notes are detail-only; playback surfaces never read them.
            showNotesHTML: nil,
            publishedAt: episode.publishedAt,
            duration: episode.duration,
            audioURL: episode.audioURL.flatMap(URL.init(string:)),
            artworkURL: episode.artworkURL.flatMap(URL.init(string:)),
            guid: episode.guid
        )
    }

    func resumePosition(for episodeID: String) -> TimeInterval {
        guard let progress = progressRecord(for: episodeID),
              !progress.isPlayed
        else {
            return 0
        }

        return progress.position
    }

    func progressRecord(for episodeID: String) -> EpisodeProgressRecord? {
        progressByEpisodeID[episodeID]
    }

    func progressSummary(for episode: EpisodeListItemSnapshot) -> EpisodeProgressSummary {
        guard let progress = progressRecord(for: episode.episodeID) else {
            return EpisodeProgressSummary(
                position: 0,
                duration: episode.duration,
                fractionCompleted: 0,
                remaining: episode.duration,
                isCompleted: false
            )
        }

        let duration = sanitizedDuration(progress.duration ?? episode.duration)
        let position = sanitizedPosition(progress.position, duration: duration)
        let fractionCompleted: Double
        let remaining: TimeInterval?
        if let duration, duration > 0 {
            fractionCompleted = min(max(position / duration, 0), 1)
            remaining = max(duration - position, 0)
        } else {
            fractionCompleted = 0
            remaining = nil
        }

        return EpisodeProgressSummary(
            position: position,
            duration: duration,
            fractionCompleted: fractionCompleted,
            remaining: remaining,
            isCompleted: progress.isPlayed || Self.isPlayed(position: position, duration: duration)
        )
    }

    func canRestorePlayback(for episode: EpisodeListItemSnapshot) -> Bool {
        !progressSummary(for: episode).isCompleted
    }

    @discardableResult
    func updateProgress(
        episodeID: String,
        podcastID: String,
        position: TimeInterval,
        duration: TimeInterval?,
        modelContext: ModelContext,
        refreshObservableProgress: Bool = true
    ) -> Bool {
        updateProgressRecord(
            episodeID: episodeID,
            podcastID: podcastID,
            position: position,
            duration: duration,
            isPlayed: Self.isPlayed(position: position, duration: duration),
            modelContext: modelContext,
            refreshObservableProgress: refreshObservableProgress
        )
    }

    @discardableResult
    func markEpisodePlayed(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        let duration = sanitizedDuration(episode.duration)
        let position = duration ?? 0

        return updateProgressRecord(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            position: position,
            duration: duration,
            isPlayed: true,
            modelContext: modelContext
        )
    }

    @discardableResult
    func updateArtworkPreview(
        _ preview: ArtworkPreview,
        for episode: EpisodeListItemSnapshot
    ) -> Bool {
        guard preview.matchesArtworkURLString(episode.artworkURL),
              let index = episodeIndexByID[episode.episodeID],
              episodes[index].artworkPreview?.storageSignature != preview.storageSignature
        else {
            return false
        }

        episodes[index].artworkPreview = preview
        let episodeID = episode.episodeID
        let artworkURL = episode.artworkURL
        enqueueCacheWrite { localCache in
            try await localCache.updateEpisodeArtworkPreview(preview, episodeID: episodeID, artworkURL: artworkURL)
        }
        return true
    }

    @discardableResult
    func updateArtworkPreview(
        _ preview: ArtworkPreview,
        for podcast: PodcastCacheSnapshot
    ) -> Bool {
        guard activePodcastIDs.contains(podcast.feedURL),
              preview.matchesArtworkURLString(podcast.artworkURL),
              var storedPodcast = podcastCacheByFeedURL[podcast.feedURL],
              storedPodcast.artworkPreview?.storageSignature != preview.storageSignature
        else {
            return false
        }

        storedPodcast.artworkPreview = preview
        podcastCacheByFeedURL[podcast.feedURL] = storedPodcast
        let feedURL = podcast.feedURL
        let artworkURL = podcast.artworkURL
        enqueueCacheWrite { localCache in
            try await localCache.updatePodcastArtworkPreview(preview, feedURL: feedURL, artworkURL: artworkURL)
        }
        return true
    }

    /// Awaits queued asynchronous cache writes (artwork previews). Test hook.
    func waitForPendingCacheWrites() async {
        await pendingCacheWriteTask?.value
    }

    @discardableResult
    private func updateProgressRecord(
        episodeID: String,
        podcastID: String,
        position: TimeInterval,
        duration: TimeInterval?,
        isPlayed: Bool,
        modelContext: ModelContext,
        refreshObservableProgress: Bool = true
    ) -> Bool {
        do {
            if let existing = try progressRecord(
                episodeID: episodeID,
                podcastID: podcastID,
                modelContext: modelContext
            ) {
                guard Self.hasMeaningfulProgressChange(
                    existing,
                    position: position,
                    duration: duration,
                    isPlayed: isPlayed
                ) else {
                    return false
                }

                existing.position = position
                existing.duration = duration
                existing.isPlayed = isPlayed
                existing.updatedAt = .now
            } else {
                modelContext.insert(
                    EpisodeProgressRecord(
                        episodeID: episodeID,
                        podcastID: podcastID,
                        position: position,
                        duration: duration,
                        isPlayed: isPlayed
                    )
                )
            }

            try modelContext.save()
            if refreshObservableProgress {
                try reloadProgressRecords(modelContext: modelContext)
            }
            return true
        } catch {
            recordFailure(error)
            return false
        }
    }

    @discardableResult
    func clearProgress(
        for episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        do {
            let records = try progressRecords(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                modelContext: modelContext
            )
            guard !records.isEmpty else {
                return false
            }

            for record in records {
                modelContext.delete(record)
            }

            try modelContext.save()
            try reloadProgressRecords(modelContext: modelContext)
            return true
        } catch {
            recordFailure(error)
            return false
        }
    }

    private func refresh(
        subscription: SubscriptionRecord,
        generation: Int,
        modelContext: ModelContext
    ) async throws {
        let feedURLString = subscription.feedURL
        refreshingFeedURLs.insert(feedURLString)
        let startedAt = Date.now

        defer {
            refreshingFeedURLs.remove(feedURLString)
        }

        guard let feedURL = URL(string: feedURLString),
              feedURL.scheme != nil,
              feedURL.host != nil
        else {
            try await recordRefreshLog(
                feedURL: feedURLString,
                startedAt: startedAt,
                errorMessage: OpenCastCoreError.invalidFeedURL.localizedDescription,
                generation: generation
            )
            return
        }

        do {
            let snapshot = try await feedService.fetchFeed(at: feedURL)
            try Task.checkCancellation()
            try ensureCurrentGeneration(generation)
            guard try await upsert(snapshot: snapshot, modelContext: modelContext, subscribe: false) else {
                return
            }
            try await recordRefreshLog(
                feedURL: feedURLString,
                startedAt: startedAt,
                errorMessage: nil,
                generation: generation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await recordRefreshLog(
                feedURL: feedURLString,
                startedAt: startedAt,
                errorMessage: error.localizedDescription,
                generation: generation
            )
        }
    }

    private func refreshAll(
        feedURLStrings: [String],
        generation: Int,
        modelContext: ModelContext
    ) async throws {
        let feedURLStrings = uniqueFeedURLStrings(from: feedURLStrings)
        guard !feedURLStrings.isEmpty else {
            return
        }

        let startedAt = Date.now
        refreshingFeedURLs.formUnion(feedURLStrings)

        let feedService = self.feedService
        do {
            try await withThrowingTaskGroup(of: FeedRefreshResult.self) { group in
                for feedURLString in feedURLStrings {
                    group.addTask {
                        await Self.fetchRefreshResult(
                            feedURLString: feedURLString,
                            feedService: feedService
                        )
                    }
                }

                for try await result in group {
                    try Task.checkCancellation()
                    try ensureCurrentGeneration(generation)
                    try await applyRefreshResult(
                        result,
                        startedAt: startedAt,
                        generation: generation,
                        modelContext: modelContext
                    )
                }
            }
        } catch is CancellationError {
            refreshingFeedURLs.subtract(feedURLStrings)
            throw CancellationError()
        }
    }

    nonisolated private static func fetchRefreshResult(
        feedURLString: String,
        feedService: any FeedService
    ) async -> FeedRefreshResult {
        guard let feedURL = URL(string: feedURLString),
              feedURL.scheme != nil,
              feedURL.host != nil
        else {
            return FeedRefreshResult(
                feedURLString: feedURLString,
                outcome: .failure(OpenCastCoreError.invalidFeedURL.localizedDescription)
            )
        }

        do {
            let snapshot = try await feedService.fetchFeed(at: feedURL)
            try Task.checkCancellation()
            return FeedRefreshResult(feedURLString: feedURLString, outcome: .success(snapshot))
        } catch is CancellationError {
            return FeedRefreshResult(feedURLString: feedURLString, outcome: .cancelled)
        } catch {
            if Task.isCancelled {
                return FeedRefreshResult(feedURLString: feedURLString, outcome: .cancelled)
            }
            return FeedRefreshResult(feedURLString: feedURLString, outcome: .failure(error.localizedDescription))
        }
    }

    private func applyRefreshResult(
        _ result: FeedRefreshResult,
        startedAt: Date,
        generation: Int,
        modelContext: ModelContext
    ) async throws {
        defer {
            refreshingFeedURLs.remove(result.feedURLString)
        }

        switch result.outcome {
        case .success(let snapshot):
            do {
                guard try await upsert(snapshot: snapshot, modelContext: modelContext, subscribe: false) else {
                    return
                }
                try await recordRefreshLog(
                    feedURL: result.feedURLString,
                    startedAt: startedAt,
                    errorMessage: nil,
                    generation: generation
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await recordRefreshLog(
                    feedURL: result.feedURLString,
                    startedAt: startedAt,
                    errorMessage: error.localizedDescription,
                    generation: generation
                )
            }
        case .failure(let message):
            try await recordRefreshLog(
                feedURL: result.feedURLString,
                startedAt: startedAt,
                errorMessage: message,
                generation: generation
            )
        case .cancelled:
            throw CancellationError()
        }
    }

    /// Refresh logs are written once, on completion. Cancelled refreshes write
    /// nothing, matching the previous insert-then-delete-on-cancel behavior.
    private func recordRefreshLog(
        feedURL: String,
        startedAt: Date,
        errorMessage: String?,
        generation: Int
    ) async throws {
        try ensureCurrentGeneration(generation)
        try await localCache.insertRefreshLog(
            RefreshLogSnapshot(
                feedURL: feedURL,
                startedAt: startedAt,
                finishedAt: .now,
                errorMessage: errorMessage
            ),
            prunedTo: Self.refreshLogRetentionLimit
        )
    }

    private func importLegacyCacheIfNeeded(modelContext: ModelContext) async {
        do {
            guard try await !localCache.hasCompletedLegacyImport() else {
                return
            }

            let podcastRecords = try modelContext.fetch(FetchDescriptor<PodcastCacheRecord>())
            let episodeRecords = try modelContext.fetch(FetchDescriptor<EpisodeCacheRecord>())
            let refreshLogRecords = try modelContext.fetch(FetchDescriptor<RefreshLogRecord>())
            try await localCache.importLegacyCache(
                podcasts: podcastRecords.map(PodcastCacheSnapshot.init(legacyRecord:)),
                episodes: episodeRecords.map(EpisodeDetailSnapshot.init(legacyRecord:)),
                refreshLogs: refreshLogRecords.map(RefreshLogSnapshot.init(legacyRecord:))
            )

            // SQLite is the source of truth from here on; reclaim the legacy rows.
            for record in podcastRecords {
                modelContext.delete(record)
            }
            for record in episodeRecords {
                modelContext.delete(record)
            }
            for record in refreshLogRecords {
                modelContext.delete(record)
            }
            try modelContext.save()
        } catch {
            // Import failure must not block launch; legacy rows stay intact and
            // the next load retries because the completion marker is unset.
            lastErrorMessage = error.localizedDescription
        }
    }

    private func reloadFromStore(modelContext: ModelContext) async throws {
        reloadGeneration += 1
        let generation = reloadGeneration

        let cacheSnapshot = try await localCache.loadLibrary(
            activePodcastIDs: activeSubscriptionFeedURLs(modelContext: modelContext)
        )

        guard generation == reloadGeneration else {
            return
        }

        // Fetch SwiftData state after the suspension: synchronous mutators
        // (progress writes, unsubscribe) can run while the SQLite load is in
        // flight, and publishing a pre-await fetch would resurrect deleted
        // model objects. If the active set changed mid-load, the mutator's own
        // follow-up reload republishes a consistent episode list.
        let activeSubscriptions = try modelContext.fetch(activeSubscriptionsDescriptor())
        subscriptions = activeSubscriptions
        activePodcastIDs = Set(activeSubscriptions.map(\.feedURL))
        progressRecords = sortedProgressRecords(try modelContext.fetch(allProgressRecordsDescriptor()))
        rebuildProgressByEpisodeID()
        episodes = cacheSnapshot.episodes
        visibleEpisodeIDs = Set(cacheSnapshot.episodes.map(\.episodeID))
        podcastCacheByFeedURL = cacheSnapshot.podcastsByFeedURL
        refreshLogs = cacheSnapshot.refreshLogs
        rebuildEpisodeIndexes()
        rebuildLatestRefreshLogByFeedURL()
    }

    private func activeSubscriptionFeedURLs(modelContext: ModelContext) throws -> Set<String> {
        let fetchedSubscriptions = try modelContext.fetch(FetchDescriptor<SubscriptionRecord>())
        return Set(fetchedSubscriptions.filter { !$0.isArchived }.map(\.feedURL))
    }

    private func reloadProgressRecords(modelContext: ModelContext) throws {
        let fetchedProgressRecords = sortedProgressRecords(
            try modelContext.fetch(allProgressRecordsDescriptor())
        )
        guard !Self.progressRecords(
            progressRecords,
            match: fetchedProgressRecords
        ) else {
            return
        }

        progressRecords = fetchedProgressRecords
        rebuildProgressByEpisodeID()
    }

    private func enqueueCacheWrite(
        _ write: @escaping @Sendable (any LocalLibraryCacheStore) async throws -> Void
    ) {
        let localCache = localCache
        let previousTask = pendingCacheWriteTask
        pendingCacheWriteTask = Task { [weak self] in
            await previousTask?.value
            do {
                try await write(localCache)
            } catch {
                self?.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func progressRecord(
        episodeID: String,
        podcastID: String,
        modelContext: ModelContext
    ) throws -> EpisodeProgressRecord? {
        var descriptor = progressRecordsDescriptor(episodeID: episodeID, podcastID: podcastID)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func progressRecords(
        episodeID: String,
        podcastID: String,
        modelContext: ModelContext
    ) throws -> [EpisodeProgressRecord] {
        let descriptor = progressRecordsDescriptor(episodeID: episodeID, podcastID: podcastID)
        return try modelContext.fetch(descriptor)
    }

    private func progressRecordsDescriptor(
        episodeID: String,
        podcastID: String
    ) -> FetchDescriptor<EpisodeProgressRecord> {
        FetchDescriptor<EpisodeProgressRecord>(
            predicate: #Predicate { record in
                record.episodeID == episodeID && record.podcastID == podcastID
            }
        )
    }

    private func activeSubscriptionsDescriptor() -> FetchDescriptor<SubscriptionRecord> {
        FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { record in
                !record.isArchived
            },
            sortBy: [
                SortDescriptor(\.title),
                SortDescriptor(\.feedURL)
            ]
        )
    }

    private func allProgressRecordsDescriptor() -> FetchDescriptor<EpisodeProgressRecord> {
        FetchDescriptor<EpisodeProgressRecord>()
    }

    private func sortedProgressRecords(_ records: [EpisodeProgressRecord]) -> [EpisodeProgressRecord] {
        records.sorted { lhs, rhs in
            if lhs.podcastID != rhs.podcastID {
                return lhs.podcastID < rhs.podcastID
            }
            if lhs.episodeID != rhs.episodeID {
                return lhs.episodeID < rhs.episodeID
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            if lhs.position != rhs.position {
                return lhs.position < rhs.position
            }
            if lhs.duration != rhs.duration {
                return (lhs.duration ?? 0) < (rhs.duration ?? 0)
            }
            return !lhs.isPlayed && rhs.isPlayed
        }
    }

    private static func subscriptionRecords(
        _ lhs: [SubscriptionRecord],
        match rhs: [SubscriptionRecord]
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        for (lhsRecord, rhsRecord) in zip(lhs, rhs) {
            guard lhsRecord.feedURL == rhsRecord.feedURL,
                  lhsRecord.title == rhsRecord.title,
                  lhsRecord.author == rhsRecord.author,
                  lhsRecord.artworkURL == rhsRecord.artworkURL,
                  lhsRecord.subscribedAt == rhsRecord.subscribedAt,
                  lhsRecord.lastRefreshAt == rhsRecord.lastRefreshAt,
                  lhsRecord.isArchived == rhsRecord.isArchived,
                  lhsRecord.isVoiceBoostEnabled == rhsRecord.isVoiceBoostEnabled
            else {
                return false
            }
        }

        return true
    }

    private static func progressRecords(
        _ lhs: [EpisodeProgressRecord],
        match rhs: [EpisodeProgressRecord]
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        for (lhsRecord, rhsRecord) in zip(lhs, rhs) {
            guard lhsRecord.episodeID == rhsRecord.episodeID,
                  lhsRecord.podcastID == rhsRecord.podcastID,
                  lhsRecord.position == rhsRecord.position,
                  lhsRecord.duration == rhsRecord.duration,
                  lhsRecord.isPlayed == rhsRecord.isPlayed,
                  lhsRecord.updatedAt == rhsRecord.updatedAt
            else {
                return false
            }
        }

        return true
    }

    private func upsert(
        snapshot: FeedSnapshot,
        modelContext: ModelContext,
        subscribe: Bool
    ) async throws -> Bool {
        let canonicalFeedURL = snapshot.podcast.id.rawValue
        let now = Date.now

        var subscriptionDescriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { record in
                record.feedURL == canonicalFeedURL
            }
        )
        subscriptionDescriptor.fetchLimit = 1
        let hasExistingSubscription = try modelContext.fetch(subscriptionDescriptor).first != nil
        guard hasExistingSubscription || subscribe else {
            // The feed was unsubscribed while its refresh was in flight;
            // writing the cache now would resurrect rows nothing deletes again.
            return false
        }

        try await localCache.upsertCache(from: snapshot, refreshedAt: now)

        if let existingSubscription = try modelContext.fetch(subscriptionDescriptor).first {
            existingSubscription.title = snapshot.podcast.title
            existingSubscription.author = snapshot.podcast.author
            existingSubscription.artworkURL = snapshot.podcast.artworkURL?.absoluteString
            existingSubscription.lastRefreshAt = now
            existingSubscription.isArchived = false
        } else if subscribe {
            modelContext.insert(
                SubscriptionRecord(
                    feedURL: canonicalFeedURL,
                    title: snapshot.podcast.title,
                    author: snapshot.podcast.author,
                    artworkURL: snapshot.podcast.artworkURL?.absoluteString,
                    lastRefreshAt: now
                )
            )
        } else {
            // The feed was unsubscribed while its refresh was in flight;
            // remove the just-written local cache so the unsubscribe stays complete.
            try await localCache.deleteCache(forPodcastID: canonicalFeedURL)
            return false
        }

        try modelContext.save()
        return true
    }

    private func staleFeedURLStrings(now: Date) -> [String] {
        subscriptions.compactMap { subscription in
            guard let lastRefreshActivity = lastRefreshActivity(for: subscription) else {
                return subscription.feedURL
            }

            return now.timeIntervalSince(lastRefreshActivity) >= Self.foregroundRefreshInterval
                ? subscription.feedURL
                : nil
        }
    }

    private func lastRefreshActivity(for subscription: SubscriptionRecord) -> Date? {
        [
            subscription.lastRefreshAt,
            latestRefreshLogByFeedURL[subscription.feedURL]?.startedAt
        ]
        .compactMap(\.self)
        .max()
    }

    private func uniqueFeedURLStrings(from feedURLStrings: [String]) -> [String] {
        var seenFeedURLStrings: Set<String> = []
        return feedURLStrings.filter { seenFeedURLStrings.insert($0).inserted }
    }

    private func ensureCurrentGeneration(_ generation: Int) throws {
        if generation != writeGeneration {
            // Data nuke invalidation should unwind refresh work like cancellation,
            // without surfacing a user-visible refresh error.
            throw CancellationError()
        }
    }

    static func isPlayed(position: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0, position > 0 else {
            return false
        }

        let clampedPosition = min(max(position, 0), duration)
        let remainingThreshold = min(completedEpisodeRemainingThreshold, duration * 0.5)
        return duration - clampedPosition < remainingThreshold
    }

    private static func hasMeaningfulProgressChange(
        _ existing: EpisodeProgressRecord,
        position: TimeInterval,
        duration: TimeInterval?,
        isPlayed: Bool
    ) -> Bool {
        if existing.isPlayed != isPlayed {
            return true
        }

        if hasMeaningfulDurationChange(existing.duration, duration) {
            return true
        }

        return abs(existing.position - position) >= 1
    }

    private static func hasMeaningfulDurationChange(
        _ existing: TimeInterval?,
        _ updated: TimeInterval?
    ) -> Bool {
        switch (existing, updated) {
        case (.none, .none):
            return false
        case (.none, .some), (.some, .none):
            return true
        case let (existing?, updated?):
            guard existing.isFinite, updated.isFinite else {
                return existing != updated
            }
            return abs(existing - updated) >= 1
        }
    }

    private func rebuildEpisodeIndexes() {
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(episodes.count)
        var indicesByPodcastID: [String: [Int]] = [:]
        for (index, episode) in episodes.enumerated() {
            if indexByID[episode.episodeID] == nil {
                indexByID[episode.episodeID] = index
            }
            indicesByPodcastID[episode.podcastID, default: []].append(index)
        }
        episodeIndexByID = indexByID
        episodeIndicesByPodcastID = indicesByPodcastID
    }

    private func rebuildProgressByEpisodeID() {
        var progressByID: [String: EpisodeProgressRecord] = [:]
        progressByID.reserveCapacity(progressRecords.count)
        for record in progressRecords {
            if let existing = progressByID[record.episodeID], existing.updatedAt >= record.updatedAt {
                continue
            }
            progressByID[record.episodeID] = record
        }
        progressByEpisodeID = progressByID
    }

    private func rebuildLatestRefreshLogByFeedURL() {
        latestRefreshLogByFeedURL = Dictionary(
            refreshLogs.map { ($0.feedURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func recordFailure(_ error: Error) {
        let message = error.localizedDescription
        state = .failed(message)
        lastErrorMessage = message
    }
}

private func sanitizedDuration(_ duration: TimeInterval?) -> TimeInterval? {
    guard let duration, duration.isFinite, duration > 0 else {
        return nil
    }

    return duration
}

private func sanitizedPosition(_ position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
    let lowerBounded = position.isFinite ? max(0, position) : 0
    guard let duration else {
        return lowerBounded
    }

    return min(lowerBounded, duration)
}

private struct FeedRefreshResult: Sendable {
    var feedURLString: String
    var outcome: FeedRefreshOutcome
}

private enum FeedRefreshOutcome: Sendable {
    case success(FeedSnapshot)
    case failure(String)
    case cancelled
}
