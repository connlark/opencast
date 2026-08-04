import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class LibraryStore {
    static let refreshLogRetentionLimit = 50
    static let completedEpisodeRemainingThreshold: TimeInterval = 60
    static let foregroundRefreshInterval: TimeInterval = 60 * 60
    static let trivialProgressPrunableMaxPosition: TimeInterval = 60
    static let trivialProgressPrunableMinAge: TimeInterval = 90 * 24 * 60 * 60

    enum State: Equatable {
        case idle
        case loading
        case refreshing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var subscriptions: [SubscriptionRecord] = []
    private(set) var episodes: [EpisodeListItemSnapshot] = []
    @ObservationIgnored private(set) var progressRecords: [EpisodeProgressRecord] = []
    /// Per-feed refresh-log projection (latest log per feed, plus its latest
    /// success), newest first. Full history: `loadAllRefreshLogs()`.
    private(set) var refreshLogs: [RefreshLogSnapshot] = []
    var refreshingFeedURLs: Set<String> {
        Set(refreshingFeedURLCounts.keys)
    }
    private(set) var activePodcastIDs: Set<String> = []
    private(set) var visibleEpisodeIDs: Set<String> = []
    private(set) var podcastCacheByFeedURL: [String: PodcastCacheSnapshot] = [:]
    private(set) var latestRefreshLogByFeedURL: [String: RefreshLogSnapshot] = [:]
    private(set) var latestSuccessfulRefreshByFeedURL: [String: Date] = [:]
    private(set) var lastErrorMessage: String?
    private(set) var subscriptionAddedToken = 0
    private(set) var refreshCompletedToken = 0

    /// Counts this store's own synced-store progress saves so the
    /// remote-change observer can skip the reload each one would otherwise
    /// trigger (one credit per save; see `SyncedStoreRemoteChangeArbiter`).
    @ObservationIgnored private(set) var syncedStoreSelfSaveCount = 0
    @ObservationIgnored private var hasPrunedTrivialProgressThisLaunch = false
    @ObservationIgnored private var lastSyncedProgressProbe: SyncedProgressProbe?
    /// Times the synced-reload probe skipped the full progress refetch. Test hook.
    @ObservationIgnored private(set) var syncedProgressProbeSkipCount = 0

    // Busy-marker bookkeeping is reference-counted through the begin/end
    // helpers so overlapping flows (a single-feed refresh during a bulk
    // refresh) provably balance on success, error, and cancellation. Rows
    // observe their feed's activity object, so per-feed marker changes never
    // invalidate every subscription row.
    @ObservationIgnored private var refreshingFeedURLCounts: [String: Int] = [:]
    @ObservationIgnored private var refreshActivityByFeedURL: [String: FeedRefreshActivity] = [:]
    @ObservationIgnored private let feedService: any FeedService
    @ObservationIgnored private let localCache: any LocalLibraryCacheStore
    /// Episode-keyed device-local stores (downloads, transcripts, ad
    /// analyses) that identity reconciliation carries across an ID change;
    /// wired by OpenCastAppModel at composition.
    @ObservationIgnored var episodeSidecarMigrators: [any EpisodeIdentitySidecarMigrating] = []

    /// Feeds whose refreshes keep landing on a different host: the podcast
    /// page offers "Update Feed Address" instead of migrating automatically,
    /// because redirects are routinely CDN noise. Session-scoped state.
    private(set) var suggestedFeedMigrationURLsByFeedURL: [String: URL] = [:]

    /// Server-reported notification poll health per accepted feed, replaced
    /// wholesale from each successful subscription sync. Advisory UI only.
    private(set) var notificationFeedHealthByFeedURL: [String: NotificationFeedHealth] = [:]
    private static let redirectDivergenceThreshold = 3
    @ObservationIgnored private var redirectDivergenceByFeedURL: [String: (targetCanonicalURL: String, count: Int)] = [:]
    @ObservationIgnored private var httpsUpgradeProbedFeedURLs: Set<String> = []
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var episodeIndexByID: [String: Int] = [:]
    @ObservationIgnored private var episodeIndicesByPodcastID: [String: [Int]] = [:]
    // Existing rows observe their SwiftData model directly. This revision is
    // reserved for index membership changes and out-of-band store reloads.
    private var progressIndexRevision = 0
    @ObservationIgnored private var progressByEpisodeID: [String: EpisodeProgressRecord] = [:]
    @ObservationIgnored private var pendingCacheWriteTask: Task<Void, Never>?
    // Resolved artwork previews live beside `episodes`, not inside it: writing
    // episodes[index] republishes the whole array and re-diffs every List that
    // reads it — once per newly realized row during a scroll.
    private var artworkPreviewOverridesByEpisodeID: [String: ArtworkPreview] = [:]

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

    /// Full retained refresh-log history for diagnostics; the published
    /// `refreshLogs` carries only the per-feed-latest projection.
    /// Returns nil on a store failure so callers can avoid caching the miss.
    func loadAllRefreshLogs() async -> [RefreshLogSnapshot]? {
        do {
            return try await localCache.allRefreshLogs()
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
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
        // Advisory notification poll health; absence is just "no data".
        notificationFeedHealthByFeedURL = (try? await localCache.notificationFeedHealthByFeedURL()) ?? [:]
    }

    /// Persists and republishes the server-reported notification poll health
    /// from a successful subscription sync. Advisory data: a failed write only
    /// costs the diagnostics display, never the sync.
    func recordNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async {
        try? await localCache.replaceNotificationFeedHealth(records)
        notificationFeedHealthByFeedURL = Dictionary(
            records.map { ($0.feedURL, $0.health) },
            uniquingKeysWith: { first, _ in first }
        )
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
            let fetchedSubscriptions = try modelContext.fetch(activeSubscriptionsDescriptor())
            let fetchedActivePodcastIDs = Set(fetchedSubscriptions.map(\.feedURL))

            let activePodcastIDsChanged = previousActivePodcastIDs != fetchedActivePodcastIDs
            let activeSubscriptionRecordsChanged = !Self.subscriptionRecords(
                previousSubscriptions,
                match: fetchedSubscriptions
            )

            // Progress is the large table, so a cheap probe (row count +
            // newest updatedAt) gates its full refetch-and-compare; any
            // mismatch takes the full reload. Subscriptions stay a plain
            // fetch: the table is small and the records carry no updatedAt
            // to probe (adding one would be a synced-schema change).
            let progressProbe = try syncedProgressProbe(modelContext: modelContext)
            let progressRecordsChanged: Bool
            if progressProbe == lastSyncedProgressProbe {
                syncedProgressProbeSkipCount += 1
                progressRecordsChanged = false
            } else {
                let fetchedProgressRecords = try modelContext.fetch(allProgressRecordsDescriptor())
                progressRecordsChanged = !Self.progressRecords(
                    progressRecords,
                    match: fetchedProgressRecords
                )
                if progressRecordsChanged {
                    progressRecords = fetchedProgressRecords
                    rebuildProgressByEpisodeID()
                }
                lastSyncedProgressProbe = progressProbe
            }

            if activeSubscriptionRecordsChanged {
                subscriptions = fetchedSubscriptions
            }
            if activePodcastIDsChanged {
                activePodcastIDs = fetchedActivePodcastIDs
                episodes = episodes.filter { fetchedActivePodcastIDs.contains($0.podcastID) }
                visibleEpisodeIDs = Set(episodes.map(\.episodeID))
                rebuildEpisodeIndexes()
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

    private struct SyncedProgressProbe: Equatable {
        var count: Int
        var latestUpdatedAt: Date?
    }

    private func syncedProgressProbe(modelContext: ModelContext) throws -> SyncedProgressProbe {
        let count = try modelContext.fetchCount(FetchDescriptor<EpisodeProgressRecord>())
        var latestDescriptor = FetchDescriptor<EpisodeProgressRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        latestDescriptor.fetchLimit = 1
        let latestUpdatedAt = try modelContext.fetch(latestDescriptor).first?.updatedAt
        return SyncedProgressProbe(count: count, latestUpdatedAt: latestUpdatedAt)
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
        // cannot start a duplicate refresh while this one is in flight.
        beginRefreshing([feedURL])
        defer {
            endRefreshing([feedURL])
        }
        do {
            guard let subscription = try activeSubscription(feedURL: feedURL, modelContext: modelContext) else {
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
            // The refresh set only needs the active feed URLs; the trailing
            // reload applies results, so a leading full-library reload would
            // pay the whole SQLite materialization for a subscription fetch.
            let feedURLStrings = try modelContext.fetch(activeSubscriptionsDescriptor()).map(\.feedURL)
            try await refreshAll(
                feedURLStrings: feedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            try await reloadFromStore(modelContext: modelContext)
            state = .idle
            refreshCompletedToken += 1
        } catch is CancellationError {
            try? await reloadFromStore(modelContext: modelContext)
            state = .idle
        } catch {
            recordFailure(error)
        }
    }

    func refreshAllIfStale(modelContext: ModelContext, now: Date = .now) async {
        guard state != .refreshing, refreshingFeedURLCounts.isEmpty else {
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
            try? await reloadFromStore(modelContext: modelContext)
            state = .idle
        } catch {
            recordFailure(error)
        }
    }

    @discardableResult
    func refreshFeedsNeedingLocalCache(modelContext: ModelContext) async -> Bool {
        guard state != .refreshing, refreshingFeedURLCounts.isEmpty else {
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
            return true
        } catch is CancellationError {
            try? await reloadFromStore(modelContext: modelContext)
            state = .idle
            return false
        } catch {
            recordFailure(error)
            return false
        }
    }

    func unsubscribe(
        feedURL: String,
        modelContext: ModelContext,
        downloadStore: DownloadStore? = nil,
        clearListeningHistory: Bool = false
    ) async {
        do {
            try downloadStore?.deleteDownloads(forPodcastID: feedURL, modelContext: modelContext)

            let targetFeedURL = feedURL
            let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: feedURL)
            // The subscription table is small; matching on the canonical form
            // also catches legacy copies whose raw URL drifted.
            let subscriptions = try modelContext.fetch(FetchDescriptor<SubscriptionRecord>())
                .filter { URLCanonicalizer.canonicalString(forRawString: $0.feedURL) == canonicalFeedURL }
            // Progress records are kept by default so played/position state
            // survives unsubscribe (and resubscribe) on every device.
            let progressRecords = clearListeningHistory
                ? try modelContext.fetch(
                    FetchDescriptor<EpisodeProgressRecord>(
                        predicate: #Predicate { record in
                            record.podcastID == targetFeedURL
                        }
                    )
                )
                : []
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

            // Local deletes alone don't stick: a CloudKit copy this device
            // hasn't imported yet would re-sync and resurrect the feed on
            // every device. Tombstones make the delete authoritative;
            // repair enforces them at import on all peers.
            let deletedAt = Date.now
            modelContext.insert(
                SyncTombstoneRecord(scope: .subscription, feedURL: canonicalFeedURL, deletedAt: deletedAt)
            )
            if clearListeningHistory {
                modelContext.insert(
                    SyncTombstoneRecord(scope: .feedProgress, feedURL: canonicalFeedURL, deletedAt: deletedAt)
                )
            }

            try modelContext.save()
            syncedStoreSelfSaveCount += 1
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

    func isAdAutoDetectEnabled(forPodcastID podcastID: String) -> Bool {
        subscriptions.first { $0.feedURL == podcastID }?.isAdAutoDetectEnabled ?? false
    }

    @discardableResult
    func setAdAutoDetectEnabled(
        _ isEnabled: Bool,
        feedURL: String,
        modelContext: ModelContext
    ) -> Bool {
        guard let subscription = subscriptions.first(where: { $0.feedURL == feedURL }) else {
            return false
        }
        guard subscription.isAdAutoDetectEnabled != isEnabled else {
            return true
        }

        let previousValue = subscription.isAdAutoDetectEnabled
        subscription.isAdAutoDetectEnabled = isEnabled

        do {
            try modelContext.save()
            syncedStoreSelfSaveCount += 1
            lastErrorMessage = nil
            return true
        } catch {
            subscription.isAdAutoDetectEnabled = previousValue
            lastErrorMessage = "Unable to update ad detection for this show: \(error.localizedDescription)"
            return false
        }
    }

    func refreshProgressRecords(modelContext: ModelContext) {
        do {
            try reloadProgressRecords(modelContext: modelContext)
        } catch {
            recordFailure(error)
        }
    }

    func repairSyncDuplicates(modelContext: ModelContext) async throws -> SyncRepairResult {
        let result = try SyncDuplicateRepairer.repair(
            modelContext: modelContext,
            claimedFeedURLsByEpisodeID: claimedFeedURLsByEpisodeID()
        )
        if result.hasChanges {
            syncedStoreSelfSaveCount += 1
        }
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
        clearAllRefreshMarkers()
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
        clearAllRefreshMarkers()
        activePodcastIDs.removeAll()
        visibleEpisodeIDs.removeAll()
        podcastCacheByFeedURL.removeAll()
        latestRefreshLogByFeedURL.removeAll()
        latestSuccessfulRefreshByFeedURL.removeAll()
        episodeIndexByID.removeAll()
        episodeIndicesByPodcastID.removeAll()
        progressByEpisodeID.removeAll()
        artworkPreviewOverridesByEpisodeID.removeAll()
        lastSyncedProgressProbe = nil
        progressIndexRevision &+= 1
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
        refreshActivity(for: feedURL).isRefreshing
    }

    private func refreshActivity(for feedURL: String) -> FeedRefreshActivity {
        if let activity = refreshActivityByFeedURL[feedURL] {
            return activity
        }

        let activity = FeedRefreshActivity()
        refreshActivityByFeedURL[feedURL] = activity
        return activity
    }

    private func beginRefreshing(_ feedURLStrings: some Sequence<String>) {
        for feedURLString in feedURLStrings {
            let count = refreshingFeedURLCounts[feedURLString, default: 0]
            refreshingFeedURLCounts[feedURLString] = count + 1
            if count == 0 {
                refreshActivity(for: feedURLString).isRefreshing = true
            }
        }
    }

    private func endRefreshing(_ feedURLStrings: some Sequence<String>) {
        for feedURLString in feedURLStrings {
            guard let count = refreshingFeedURLCounts[feedURLString] else {
                continue
            }
            if count <= 1 {
                refreshingFeedURLCounts.removeValue(forKey: feedURLString)
                refreshActivity(for: feedURLString).isRefreshing = false
            } else {
                refreshingFeedURLCounts[feedURLString] = count - 1
            }
        }
    }

    private func clearAllRefreshMarkers() {
        refreshingFeedURLCounts.removeAll()
        for activity in refreshActivityByFeedURL.values {
            activity.isRefreshing = false
        }
    }

    func latestRefreshLog(feedURL: String) -> RefreshLogSnapshot? {
        latestRefreshLogByFeedURL[feedURL]
    }

    /// Refresh recency for display: the newest local successful refresh,
    /// falling back to the synced `lastRefreshAt` snapshot (frozen after the
    /// initial subscribe) for feeds this device hasn't refreshed yet.
    func lastRefreshedAt(for subscription: SubscriptionRecord) -> Date? {
        [latestSuccessfulRefreshByFeedURL[subscription.feedURL], subscription.lastRefreshAt]
            .compactMap(\.self)
            .max()
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

        return Self.smartResumePosition(
            position: progress.position,
            updatedAt: progress.updatedAt,
            now: .now
        )
    }

    /// Resuming drops the listener mid-word; rewind a little for context,
    /// more the longer the position has sat. Every resume consumer (play
    /// path, restore, CarPlay/Siri) inherits this through `resumePosition`.
    static func smartResumePosition(
        position: TimeInterval,
        updatedAt: Date,
        now: Date
    ) -> TimeInterval {
        guard position > 0 else {
            return position
        }

        let age = now.timeIntervalSince(updatedAt)
        let rewind: TimeInterval = if age < 60 * 60 {
            3
        } else if age < 24 * 60 * 60 {
            10
        } else {
            20
        }
        return max(0, position - rewind)
    }

    func progressRecord(for episodeID: String) -> EpisodeProgressRecord? {
        _ = progressIndexRevision
        return progressByEpisodeID[episodeID]
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
            fractionCompleted = (position / duration).clamped01
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
    func markAllPlayed(forPodcastID podcastID: String, modelContext: ModelContext) -> Bool {
        let podcastEpisodes = episodes(forPodcastID: podcastID)
        guard !podcastEpisodes.isEmpty else {
            return false
        }

        do {
            let targetPodcastID = podcastID
            let storedRecords = try modelContext.fetch(
                FetchDescriptor<EpisodeProgressRecord>(
                    predicate: #Predicate { record in
                        record.podcastID == targetPodcastID
                    }
                )
            )
            let latestRecordByEpisodeID = Self.latestProgressRecordsByEpisodeID(storedRecords)

            let updatedAt = Date.now
            var hasChanges = false
            for episode in podcastEpisodes {
                let duration = sanitizedDuration(episode.duration)
                let position = duration ?? 0
                if let record = latestRecordByEpisodeID[episode.episodeID] {
                    guard Self.hasMeaningfulProgressChange(
                        record,
                        position: position,
                        duration: duration,
                        isPlayed: true
                    ) else {
                        continue
                    }
                    record.position = position
                    record.duration = duration
                    record.isPlayed = true
                    record.updatedAt = updatedAt
                } else {
                    modelContext.insert(
                        EpisodeProgressRecord(
                            episodeID: episode.episodeID,
                            podcastID: podcastID,
                            position: position,
                            duration: duration,
                            isPlayed: true,
                            updatedAt: updatedAt
                        )
                    )
                }
                hasChanges = true
            }

            guard hasChanges else {
                return false
            }

            try modelContext.save()
            syncedStoreSelfSaveCount += 1
            progressRecords = try modelContext.fetch(allProgressRecordsDescriptor())
            rebuildProgressByEpisodeID()
            lastErrorMessage = nil
            return true
        } catch {
            recordFailure(error)
            return false
        }
    }

    /// The row that resolved the preview shows it locally; the override map
    /// carries it to other appearances of the episode and the cache write
    /// persists it for the next full reload.
    func artworkPreview(for episode: EpisodeListItemSnapshot) -> ArtworkPreview? {
        if let override = artworkPreviewOverridesByEpisodeID[episode.episodeID],
           override.matchesArtworkURLString(episode.artworkURL) {
            return override
        }
        return episode.artworkPreview
    }

    @discardableResult
    func updateArtworkPreview(
        _ preview: ArtworkPreview,
        for episode: EpisodeListItemSnapshot
    ) -> Bool {
        guard preview.matchesArtworkURLString(episode.artworkURL),
              episodeIndexByID[episode.episodeID] != nil,
              artworkPreview(for: episode)?.storageSignature != preview.storageSignature
        else {
            return false
        }

        let episodeID = episode.episodeID
        artworkPreviewOverridesByEpisodeID[episodeID] = preview
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
            let updatedRecord: EpisodeProgressRecord
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
                updatedRecord = existing
            } else {
                let record = EpisodeProgressRecord(
                    episodeID: episodeID,
                    podcastID: podcastID,
                    position: position,
                    duration: duration,
                    isPlayed: isPlayed
                )
                modelContext.insert(record)
                updatedRecord = record
            }

            try modelContext.save()
            syncedStoreSelfSaveCount += 1
            if refreshObservableProgress {
                updateProgressSnapshot(with: updatedRecord)
            }
            return true
        } catch {
            recordFailure(error)
            return false
        }
    }

    /// Once-per-launch cleanup of progress rows that are preview taps someone
    /// never returned to — unsubscribed, unplayed, under a minute in, and
    /// untouched for months. Deliberately narrow: played episodes and real
    /// positions are kept forever regardless of subscription, so unsubscribe's
    /// history-keeping promise stays intact.
    @discardableResult
    func pruneTrivialUnsubscribedProgressRecords(
        modelContext: ModelContext,
        now: Date = .now
    ) -> Int {
        guard !hasPrunedTrivialProgressThisLaunch else {
            return 0
        }

        hasPrunedTrivialProgressThisLaunch = true
        // No tombstones: a feed-level tombstone would also kill the
        // non-trivial history this prune deliberately keeps. Unseen copies of
        // pruned rows can resurrect, but every device prunes them again at
        // launch, so the cleanup converges on its own.
        return deleteUnsubscribedProgressRecords(
            modelContext: modelContext,
            writingTombstonesAt: nil
        ) { record in
            !record.isPlayed
                && record.position < Self.trivialProgressPrunableMaxPosition
                && now.timeIntervalSince(record.updatedAt) > Self.trivialProgressPrunableMinAge
        }
    }

    /// User-initiated bulk clear of all played/position state for shows with
    /// no subscription record. Syncs to other devices like any progress delete.
    @discardableResult
    func clearProgressForUnsubscribedShows(modelContext: ModelContext) -> Int {
        deleteUnsubscribedProgressRecords(
            modelContext: modelContext,
            writingTombstonesAt: .now
        ) { _ in true }
    }

    private func deleteUnsubscribedProgressRecords(
        modelContext: ModelContext,
        writingTombstonesAt tombstoneDate: Date?,
        matching isPrunable: (EpisodeProgressRecord) -> Bool
    ) -> Int {
        do {
            // Archived subscriptions still mark a show as deliberately kept;
            // only shows with no subscription record at all are candidates.
            let subscribedFeedURLs = Set(
                try modelContext.fetch(FetchDescriptor<SubscriptionRecord>()).map(\.feedURL)
            )
            let prunableRecords = try modelContext.fetch(allProgressRecordsDescriptor())
                .filter { record in
                    !subscribedFeedURLs.contains(record.podcastID) && isPrunable(record)
                }
            guard !prunableRecords.isEmpty else {
                return 0
            }

            for record in prunableRecords {
                modelContext.delete(record)
            }

            if let tombstoneDate {
                let clearedFeedURLs = Set(
                    prunableRecords.map { URLCanonicalizer.canonicalString(forRawString: $0.podcastID) }
                )
                for feedURL in clearedFeedURLs {
                    modelContext.insert(
                        SyncTombstoneRecord(scope: .feedProgress, feedURL: feedURL, deletedAt: tombstoneDate)
                    )
                }
            }

            try modelContext.save()
            syncedStoreSelfSaveCount += 1
            try reloadProgressRecords(modelContext: modelContext)
            return prunableRecords.count
        } catch {
            recordFailure(error)
            return 0
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
            modelContext.insert(
                SyncTombstoneRecord(
                    scope: .episodeProgress,
                    feedURL: URLCanonicalizer.canonicalString(forRawString: episode.podcastID),
                    episodeID: episode.episodeID
                )
            )

            try modelContext.save()
            syncedStoreSelfSaveCount += 1
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
        let startedAt = Date.now

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
            let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: feedURLString)
            let storedValidators = (try? await localCache.feedValidators(forPodcastID: canonicalFeedURL)) ?? nil
            let outcome = try await feedService.fetchFeedOutcome(at: feedURL, validators: storedValidators)
            try Task.checkCancellation()
            try ensureCurrentGeneration(generation)
            guard let snapshot = outcome.snapshot else {
                // Not-modified short-circuit: still a successful refresh.
                await persistValidators(outcome.validators, forPodcastID: canonicalFeedURL)
                try await recordRefreshLog(
                    feedURL: feedURLString,
                    startedAt: startedAt,
                    errorMessage: nil,
                    generation: generation
                )
                return
            }
            guard try await upsert(snapshot: snapshot, modelContext: modelContext, subscribe: false) else {
                return
            }
            await persistValidators(outcome.validators, forPodcastID: snapshot.podcast.id.rawValue)
            try await recordRefreshLog(
                feedURL: feedURLString,
                startedAt: startedAt,
                errorMessage: snapshot.isSalvaged ? RefreshLogSnapshot.partialFeedSalvageMessage : nil,
                generation: generation
            )
            try await handleFeedRelocation(
                outcome,
                feedURLString: feedURLString,
                generation: generation,
                modelContext: modelContext
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

    /// Bounded fetch fan-out shared by refreshAll and subscribeBatch: wide
    /// enough to hide network latency, narrow enough not to flood the feed
    /// hosts or starve the main actor with result application.
    static let maxConcurrentFeedRefreshes = 4

    /// OPML import's bulk subscribe: fetches run at the shared width while
    /// each subscription applies serially on the main actor. Per-feed
    /// failures accumulate; cancellation aborts the whole batch.
    func subscribeBatch(
        to feedURLStrings: [String],
        modelContext: ModelContext
    ) async throws -> BatchSubscribeResult {
        let generation = writeGeneration
        var result = BatchSubscribeResult()
        guard !feedURLStrings.isEmpty else {
            return result
        }

        let feedService = self.feedService
        let localCache = self.localCache
        try await withThrowingTaskGroup(of: FeedRefreshResult.self) { group in
            var unseededFeedURLStrings = feedURLStrings[...]
            func seedNextFetch() {
                guard let feedURLString = unseededFeedURLStrings.popFirst() else {
                    return
                }
                group.addTask {
                    await Self.fetchRefreshResult(
                        feedURLString: feedURLString,
                        feedService: feedService,
                        localCache: localCache
                    )
                }
            }

            for _ in 0..<Self.maxConcurrentFeedRefreshes {
                seedNextFetch()
            }

            for try await fetchResult in group {
                seedNextFetch()
                try Task.checkCancellation()
                try ensureCurrentGeneration(generation)
                switch fetchResult.outcome {
                case .success(let outcome):
                    guard let snapshot = outcome.snapshot else {
                        result.failures.append(
                            BatchSubscribeFailure(
                                feedURLString: fetchResult.feedURLString,
                                message: OpenCastCoreError.invalidHTTPResponse.localizedDescription
                            )
                        )
                        continue
                    }
                    do {
                        _ = try await upsert(snapshot: snapshot, modelContext: modelContext, subscribe: true)
                        await persistValidators(outcome.validators, forPodcastID: snapshot.podcast.id.rawValue)
                        result.subscribedFeedURLStrings.append(fetchResult.feedURLString)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        result.failures.append(
                            BatchSubscribeFailure(
                                feedURLString: fetchResult.feedURLString,
                                message: error.localizedDescription
                            )
                        )
                    }
                case .failure(let message):
                    result.failures.append(
                        BatchSubscribeFailure(feedURLString: fetchResult.feedURLString, message: message)
                    )
                case .cancelled:
                    throw CancellationError()
                }
            }
        }

        return result
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
        var pendingFeedURLStrings = Set(feedURLStrings)
        beginRefreshing(feedURLStrings)
        defer {
            endRefreshing(pendingFeedURLStrings)
        }

        let feedService = self.feedService
        let localCache = self.localCache
        try await withThrowingTaskGroup(of: FeedRefreshResult.self) { group in
            var unseededFeedURLStrings = feedURLStrings[...]
            func seedNextRefresh() {
                guard let feedURLString = unseededFeedURLStrings.popFirst() else {
                    return
                }
                group.addTask {
                    await Self.fetchRefreshResult(
                        feedURLString: feedURLString,
                        feedService: feedService,
                        localCache: localCache
                    )
                }
            }

            for _ in 0..<Self.maxConcurrentFeedRefreshes {
                seedNextRefresh()
            }

            for try await result in group {
                seedNextRefresh()
                try Task.checkCancellation()
                try ensureCurrentGeneration(generation)
                pendingFeedURLStrings.remove(result.feedURLString)
                try await applyRefreshResult(
                    result,
                    startedAt: startedAt,
                    generation: generation,
                    modelContext: modelContext
                )
            }
        }
    }

    nonisolated private static func fetchRefreshResult(
        feedURLString: String,
        feedService: any FeedService,
        localCache: any LocalLibraryCacheStore
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
            let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: feedURLString)
            let storedValidators = (try? await localCache.feedValidators(forPodcastID: canonicalFeedURL)) ?? nil
            let outcome = try await feedService.fetchFeedOutcome(at: feedURL, validators: storedValidators)
            try Task.checkCancellation()
            return FeedRefreshResult(feedURLString: feedURLString, outcome: .success(outcome))
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
            endRefreshing([result.feedURLString])
        }

        switch result.outcome {
        case .success(let outcome):
            do {
                guard let snapshot = outcome.snapshot else {
                    // Not-modified short-circuit: still a successful refresh.
                    await persistValidators(
                        outcome.validators,
                        forPodcastID: URLCanonicalizer.canonicalString(forRawString: result.feedURLString)
                    )
                    try await recordRefreshLog(
                        feedURL: result.feedURLString,
                        startedAt: startedAt,
                        errorMessage: nil,
                        generation: generation
                    )
                    return
                }
                guard try await upsert(snapshot: snapshot, modelContext: modelContext, subscribe: false) else {
                    return
                }
                await persistValidators(outcome.validators, forPodcastID: snapshot.podcast.id.rawValue)
                try await recordRefreshLog(
                    feedURL: result.feedURLString,
                    startedAt: startedAt,
                    errorMessage: snapshot.isSalvaged ? RefreshLogSnapshot.partialFeedSalvageMessage : nil,
                    generation: generation
                )
                try await handleFeedRelocation(
                    outcome,
                    feedURLString: result.feedURLString,
                    generation: generation,
                    modelContext: modelContext
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

    /// Validator persistence is a refresh optimization: a failed write only
    /// costs the next fetch a full download, so it never fails the refresh.
    private func persistValidators(_ validators: FeedValidators?, forPodcastID podcastID: String) async {
        guard let validators, !validators.isEmpty else {
            return
        }
        try? await localCache.updateFeedValidators(validators, forPodcastID: podcastID)
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
        progressRecords = try modelContext.fetch(allProgressRecordsDescriptor())
        rebuildProgressByEpisodeID()
        episodes = cacheSnapshot.episodes
        visibleEpisodeIDs = Set(cacheSnapshot.episodes.map(\.episodeID))
        podcastCacheByFeedURL = cacheSnapshot.podcastsByFeedURL
        refreshLogs = cacheSnapshot.refreshLogs
        rebuildEpisodeIndexes()
        rebuildLatestRefreshLogByFeedURL()
    }

    /// Which canonical feed each cached episode belongs to, for repair's
    /// variant-key normalization. Episode IDs claimed by more than one feed
    /// (same audio syndicated across shows) are excluded as ambiguous.
    private func claimedFeedURLsByEpisodeID() -> [String: String] {
        var claims: [String: String] = [:]
        claims.reserveCapacity(episodes.count)
        var ambiguousEpisodeIDs: Set<String> = []
        for episode in episodes {
            let feedURL = URLCanonicalizer.canonicalString(forRawString: episode.podcastID)
            if let existing = claims[episode.episodeID], existing != feedURL {
                ambiguousEpisodeIDs.insert(episode.episodeID)
            } else {
                claims[episode.episodeID] = feedURL
            }
        }
        for episodeID in ambiguousEpisodeIDs {
            claims.removeValue(forKey: episodeID)
        }
        return claims
    }

    private func activeSubscription(
        feedURL: String,
        modelContext: ModelContext
    ) throws -> SubscriptionRecord? {
        var descriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { record in
                record.feedURL == feedURL && !record.isArchived
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func activeSubscriptionFeedURLs(modelContext: ModelContext) throws -> Set<String> {
        var descriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { record in
                !record.isArchived
            }
        )
        descriptor.propertiesToFetch = [\.feedURL]
        return Set(try modelContext.fetch(descriptor).map(\.feedURL))
    }

    private func reloadProgressRecords(modelContext: ModelContext) throws {
        let fetchedProgressRecords = try modelContext.fetch(allProgressRecordsDescriptor())
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
            },
            sortBy: [
                SortDescriptor(\.updatedAt, order: .reverse),
                SortDescriptor(\.position, order: .reverse),
                SortDescriptor(\.duration, order: .reverse)
            ]
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
        FetchDescriptor<EpisodeProgressRecord>(
            sortBy: [
                SortDescriptor(\.podcastID),
                SortDescriptor(\.episodeID),
                SortDescriptor(\.updatedAt),
                SortDescriptor(\.position),
                SortDescriptor(\.duration)
            ]
        )
    }

    private func updateProgressSnapshot(with record: EpisodeProgressRecord) {
        if let existingIndex = progressRecords.firstIndex(where: { $0 === record }) {
            progressRecords.remove(at: existingIndex)
        }
        insertProgressRecordInOrder(record)

        let indexedRecord = progressByEpisodeID[record.episodeID]
        progressByEpisodeID[record.episodeID] = record
        if indexedRecord !== record {
            progressIndexRevision &+= 1
        }
    }

    private func insertProgressRecordInOrder(_ record: EpisodeProgressRecord) {
        var lowerBound = progressRecords.startIndex
        var upperBound = progressRecords.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if Self.progressRecordPrecedesInStore(progressRecords[middle], record) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        progressRecords.insert(record, at: lowerBound)
    }

    private static func progressRecordPrecedesInStore(
        _ lhs: EpisodeProgressRecord,
        _ rhs: EpisodeProgressRecord
    ) -> Bool {
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
        switch (lhs.duration, rhs.duration) {
        case (nil, nil):
            return false
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (lhsDuration?, rhsDuration?):
            return lhsDuration < rhsDuration
        }
    }

    private static func progressRecordPrecedesForIndex(
        _ lhs: EpisodeProgressRecord,
        _ rhs: EpisodeProgressRecord
    ) -> Bool {
        if lhs.podcastID != rhs.podcastID {
            return lhs.podcastID < rhs.podcastID
        }
        if lhs.episodeID != rhs.episodeID {
            return lhs.episodeID < rhs.episodeID
        }
        if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        if lhs.duration != rhs.duration {
            return (lhs.duration ?? 0) < (rhs.duration ?? 0)
        }
        return !lhs.isPlayed && rhs.isPlayed
    }

    private static func latestProgressRecordsByEpisodeID(
        _ progressRecords: [EpisodeProgressRecord]
    ) -> [String: EpisodeProgressRecord] {
        var latestRecordByEpisodeID: [String: EpisodeProgressRecord] = [:]
        latestRecordByEpisodeID.reserveCapacity(progressRecords.count)
        for record in progressRecords {
            if let existing = latestRecordByEpisodeID[record.episodeID] {
                guard record.updatedAt > existing.updatedAt || (
                    record.updatedAt == existing.updatedAt
                        && progressRecordPrecedesForIndex(record, existing)
                ) else {
                    continue
                }
            }
            latestRecordByEpisodeID[record.episodeID] = record
        }
        return latestRecordByEpisodeID
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
                  lhsRecord.isVoiceBoostEnabled == rhsRecord.isVoiceBoostEnabled,
                  lhsRecord.isAdAutoDetectEnabled == rhsRecord.isAdAutoDetectEnabled
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

        let preexistingEpisodes = try await localCache.cachedEpisodes(forPodcastID: canonicalFeedURL)
        try await localCache.upsertCache(from: snapshot, refreshedAt: now)
        try await reconcileEpisodeIdentities(
            preexisting: preexistingEpisodes,
            snapshot: snapshot,
            includesEstablishedSuccessors: false,
            modelContext: modelContext
        )

        // Synced-record writes are held to actual changes: every dirtied
        // field exports a CKRecord and round-trips through every device, and
        // routine refreshes used to re-write identical metadata for the whole
        // library. Refresh recency itself is deliberately device-local (the
        // refresh logs) — syncing it starved other devices' own refreshes and
        // kept every subscription record permanently churning.
        var hasSyncedChanges = false
        if let existingSubscription = try modelContext.fetch(subscriptionDescriptor).first {
            hasSyncedChanges = update(existingSubscription, from: snapshot)
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
            hasSyncedChanges = true
        } else {
            // The feed was unsubscribed while its refresh was in flight;
            // remove the just-written local cache so the unsubscribe stays complete.
            try await localCache.deleteCache(forPodcastID: canonicalFeedURL)
            return false
        }

        if hasSyncedChanges {
            try modelContext.save()
            syncedStoreSelfSaveCount += 1
        }
        return true
    }

    /// Re-keys departed episode IDs onto their re-identified successors after
    /// a cache write: publishers that add or change GUIDs (or a GUID-less
    /// feed that moves hosts) mint a whole new catalog, and without this the
    /// old rows linger as duplicates while progress, downloads, transcripts,
    /// and ad analyses stay orphaned on the dead IDs forever.
    ///
    /// Refresh passes only consider successors whose IDs are new to the cache
    /// (`includesEstablishedSuccessors: false`) so a merely-removed episode
    /// can never be folded into a long-stable one; the manual merge sweep
    /// passes `true` because its departed rows are historic duplicates whose
    /// successors are already cached. Unmatched departed rows are retained as
    /// off-feed back-catalog — deletion happens only for migrated rows.
    ///
    /// The old-ID progress rows re-key (merging when the successor already
    /// has progress) and an `episode-progress` tombstone for each old ID
    /// lands in the same save, so old-ID twins on other devices die instead
    /// of resurrecting. Tombstones index by episode ID alone, so they can
    /// never touch the migrated new-ID rows; recency is deliberately left
    /// untouched so a peer's genuinely newer progress still wins its merge.
    @discardableResult
    private func reconcileEpisodeIdentities(
        preexisting: [EpisodeListItemSnapshot],
        snapshot: FeedSnapshot,
        includesEstablishedSuccessors: Bool,
        modelContext: ModelContext
    ) async throws -> Int {
        guard !preexisting.isEmpty else {
            return 0
        }
        let canonicalFeedURL = snapshot.podcast.id.rawValue
        let snapshotIDs = Set(snapshot.episodes.map(\.id.rawValue))
        let preexistingIDs = Set(preexisting.map(\.episodeID))

        let departed = preexisting
            .filter { !snapshotIDs.contains($0.episodeID) }
            .map(EpisodeIdentityReconciler.Candidate.init(listItem:))
        guard !departed.isEmpty else {
            return 0
        }

        let successors = snapshot.episodes
            .filter { includesEstablishedSuccessors || !preexistingIDs.contains($0.id.rawValue) }
            .map(EpisodeIdentityReconciler.Candidate.init(episode:))
        guard !successors.isEmpty else {
            return 0
        }

        let matches = EpisodeIdentityReconciler.matches(departed: departed, successors: successors)
        guard !matches.isEmpty else {
            return 0
        }

        try applyIdentityMatches(matches, canonicalFeedURL: canonicalFeedURL, modelContext: modelContext)
        try modelContext.save()
        syncedStoreSelfSaveCount += 1
        try await localCache.deleteEpisodes(episodeIDs: matches.map(\.departedEpisodeID))
        return matches.count
    }

    /// The per-match migration body, shared with subscription migration; the
    /// caller owns the save (constraint: tombstones land in the same save as
    /// the records they cover).
    private func applyIdentityMatches(
        _ matches: [EpisodeIdentityReconciler.Match],
        canonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {
        let deletedAt = Date.now
        for match in matches {
            try migrateProgressRecords(
                from: match.departedEpisodeID,
                to: match.successorEpisodeID,
                canonicalFeedURL: canonicalFeedURL,
                modelContext: modelContext
            )
            for migrator in episodeSidecarMigrators {
                try migrator.migrateEpisodeSidecars(
                    from: match.departedEpisodeID,
                    to: match.successorEpisodeID,
                    canonicalPodcastID: canonicalFeedURL,
                    modelContext: modelContext
                )
            }
            try migrateAdFreePassQueueItems(
                from: match.departedEpisodeID,
                to: match.successorEpisodeID,
                canonicalFeedURL: canonicalFeedURL,
                modelContext: modelContext
            )
            modelContext.insert(
                SyncTombstoneRecord(
                    scope: .episodeProgress,
                    feedURL: canonicalFeedURL,
                    episodeID: match.departedEpisodeID,
                    deletedAt: deletedAt
                )
            )
        }
    }

    private func migrateProgressRecords(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {
        let targetOldID = oldEpisodeID
        let migratingRecords = try modelContext.fetch(
            FetchDescriptor<EpisodeProgressRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetOldID
                }
            )
        )
        guard !migratingRecords.isEmpty else {
            return
        }

        let targetNewID = newEpisodeID
        let existingRecords = try modelContext.fetch(
            FetchDescriptor<EpisodeProgressRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetNewID
                }
            )
        )
        for record in migratingRecords {
            record.episodeID = newEpisodeID
            record.podcastID = canonicalFeedURL
        }

        let group = migratingRecords + existingRecords
        if group.count > 1 {
            var mergeResult = SyncRepairResult()
            SyncDuplicateRepairer.mergeProgressGroup(
                group,
                key: .init(canonicalFeedURL: canonicalFeedURL, episodeID: newEpisodeID),
                modelContext: modelContext,
                result: &mergeResult
            )
        }
    }

    private func migrateAdFreePassQueueItems(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {
        let targetOldID = oldEpisodeID
        let queueItems = try modelContext.fetch(
            FetchDescriptor<AdFreePassQueueItemRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetOldID
                }
            )
        )
        guard !queueItems.isEmpty else {
            return
        }

        // A successor already queued makes the old items redundant — one pass
        // per episode; re-keying would strand duplicate rows forever.
        let targetNewID = newEpisodeID
        let existingItems = try modelContext.fetch(
            FetchDescriptor<AdFreePassQueueItemRecord>(
                predicate: #Predicate { record in
                    record.episodeID == targetNewID
                }
            )
        )
        guard existingItems.isEmpty else {
            for item in queueItems {
                modelContext.delete(item)
            }
            return
        }

        for item in queueItems {
            item.episodeID = newEpisodeID
            item.podcastID = canonicalFeedURL
        }
    }

    private func handleFeedRelocation(
        _ outcome: FeedFetchOutcome,
        feedURLString: String,
        generation: Int,
        modelContext: ModelContext
    ) async throws {
        try ensureCurrentGeneration(generation)
        let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: feedURLString)

        if let newFeedURL = outcome.newFeedURL,
           URLCanonicalizer.canonicalString(for: newFeedURL) != canonicalFeedURL {
            // The tag is the publisher's explicit instruction; migration
            // performs its own fetch of the new URL and only commits when
            // that fetch succeeds.
            do {
                try await migrateSubscription(
                    from: feedURLString,
                    toFeedURL: newFeedURL,
                    modelContext: modelContext
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The declared URL doesn't serve a usable feed yet; stay put.
            }
        }

        updateRedirectDivergence(feedURLString: feedURLString, finalURL: outcome.finalURL)
        try await probeHTTPSUpgradeIfNeeded(feedURLString: feedURLString, modelContext: modelContext)
    }

    private func updateRedirectDivergence(feedURLString: String, finalURL: URL?) {
        guard let finalURL,
              let subscribedHost = URL(string: feedURLString)?.host?.lowercased(),
              let finalHost = finalURL.host?.lowercased()
        else {
            return
        }
        guard finalHost != subscribedHost else {
            redirectDivergenceByFeedURL[feedURLString] = nil
            if suggestedFeedMigrationURLsByFeedURL[feedURLString] != nil {
                suggestedFeedMigrationURLsByFeedURL[feedURLString] = nil
            }
            return
        }

        let targetCanonicalURL = URLCanonicalizer.canonicalString(for: finalURL)
        var divergence = redirectDivergenceByFeedURL[feedURLString] ?? (targetCanonicalURL, 0)
        if divergence.targetCanonicalURL == targetCanonicalURL {
            divergence.count += 1
        } else {
            divergence = (targetCanonicalURL, 1)
        }
        redirectDivergenceByFeedURL[feedURLString] = divergence
        if divergence.count >= Self.redirectDivergenceThreshold {
            suggestedFeedMigrationURLsByFeedURL[feedURLString] = finalURL
        }
    }

    /// `http://` feeds stay supported and are never rewritten blindly; when
    /// the https twin demonstrably serves the same show (identity overlap),
    /// the subscription upgrades onto it. One probe per feed per launch.
    private func probeHTTPSUpgradeIfNeeded(
        feedURLString: String,
        modelContext: ModelContext
    ) async throws {
        guard let feedURL = URL(string: feedURLString),
              feedURL.scheme?.lowercased() == "http",
              !httpsUpgradeProbedFeedURLs.contains(feedURLString)
        else {
            return
        }
        httpsUpgradeProbedFeedURLs.insert(feedURLString)

        var components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        guard let httpsURL = components?.url else {
            return
        }

        do {
            try await migrateSubscription(
                from: feedURLString,
                toFeedURL: httpsURL,
                requiresIdentityOverlap: true,
                modelContext: modelContext
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No https twin, or it serves something else — keep the http feed.
        }
    }

    /// Moves a subscription onto a new canonical feed URL: fetches the new
    /// URL (the migration only commits when that fetch succeeds), re-keys
    /// episode identities through the reconciliation machinery, writes the
    /// old URL's subscription tombstone and the fresh SubscriptionRecord in
    /// the same save, then drops the old URL's local cache.
    func migrateSubscription(
        from oldFeedURLString: String,
        toFeedURL newFeedURL: URL,
        requiresIdentityOverlap: Bool = false,
        modelContext: ModelContext
    ) async throws {
        let outcome = try await feedService.fetchFeedOutcome(at: newFeedURL)
        guard let snapshot = outcome.snapshot else {
            throw OpenCastCoreError.invalidHTTPResponse
        }
        let newCanonicalFeedURL = snapshot.podcast.id.rawValue
        let oldCanonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: oldFeedURLString)
        guard newCanonicalFeedURL != oldCanonicalFeedURL else {
            return
        }

        let allSubscriptions = try modelContext.fetch(FetchDescriptor<SubscriptionRecord>())
        let oldSubscriptionRecords = allSubscriptions.filter { record in
            URLCanonicalizer.canonicalString(forRawString: record.feedURL) == oldCanonicalFeedURL
        }
        guard let template = oldSubscriptionRecords.first else {
            return
        }

        let departed = try await localCache.cachedEpisodes(forPodcastID: oldCanonicalFeedURL)
            .map(EpisodeIdentityReconciler.Candidate.init(listItem:))
        let successors = snapshot.episodes.map(EpisodeIdentityReconciler.Candidate.init(episode:))
        let matches = EpisodeIdentityReconciler.matches(departed: departed, successors: successors)
        if requiresIdentityOverlap, !departed.isEmpty, matches.isEmpty {
            throw FeedMigrationError(message: "The feed at the new address does not match this show.")
        }

        try await localCache.upsertCache(from: snapshot, refreshedAt: .now)
        try applyIdentityMatches(matches, canonicalFeedURL: newCanonicalFeedURL, modelContext: modelContext)

        let deletedAt = Date.now
        modelContext.insert(
            SyncTombstoneRecord(scope: .subscription, feedURL: oldCanonicalFeedURL, deletedAt: deletedAt)
        )
        let hasNewSubscription = allSubscriptions.contains { record in
            URLCanonicalizer.canonicalString(forRawString: record.feedURL) == newCanonicalFeedURL
        }
        if !hasNewSubscription {
            // subscribedAt must postdate the old URL's tombstone only if the
            // keys collided — they don't — but a strictly newer stamp keeps
            // the record safe under any future canonicalization drift.
            modelContext.insert(
                SubscriptionRecord(
                    feedURL: newCanonicalFeedURL,
                    title: snapshot.podcast.title,
                    author: snapshot.podcast.author,
                    artworkURL: snapshot.podcast.artworkURL?.absoluteString,
                    subscribedAt: deletedAt.addingTimeInterval(1),
                    lastRefreshAt: .now,
                    isArchived: template.isArchived,
                    isVoiceBoostEnabled: template.isVoiceBoostEnabled,
                    isAdAutoDetectEnabled: template.isAdAutoDetectEnabled
                )
            )
        }
        for record in oldSubscriptionRecords {
            modelContext.delete(record)
        }
        try modelContext.save()
        syncedStoreSelfSaveCount += 1

        try await localCache.deleteCache(forPodcastID: oldCanonicalFeedURL)
        redirectDivergenceByFeedURL[oldFeedURLString] = nil
        if suggestedFeedMigrationURLsByFeedURL[oldFeedURLString] != nil {
            suggestedFeedMigrationURLsByFeedURL[oldFeedURLString] = nil
        }
        try await reloadFromStore(modelContext: modelContext)
        try reloadProgressRecords(modelContext: modelContext)
    }

    /// Diagnostics sweep for libraries duplicated before reconciliation
    /// existed: refetches every subscribed feed and reconciles departed rows
    /// against the feed's full current catalog (successors may already be
    /// cached, which routine refreshes deliberately skip).
    func mergeDuplicateEpisodes(modelContext: ModelContext) async throws -> EpisodeMergeResult {
        var result = EpisodeMergeResult()
        let feedURLStrings = subscriptions.map(\.feedURL)
        for feedURLString in feedURLStrings {
            guard let feedURL = URL(string: feedURLString),
                  feedURL.scheme != nil,
                  feedURL.host != nil
            else {
                result.failedFeedURLs.append(feedURLString)
                continue
            }
            do {
                let snapshot = try await feedService.fetchFeed(at: feedURL)
                try Task.checkCancellation()
                let canonicalFeedURL = snapshot.podcast.id.rawValue
                let preexisting = try await localCache.cachedEpisodes(forPodcastID: canonicalFeedURL)
                result.episodesMigrated += try await reconcileEpisodeIdentities(
                    preexisting: preexisting,
                    snapshot: snapshot,
                    includesEstablishedSuccessors: true,
                    modelContext: modelContext
                )
                _ = try await upsert(snapshot: snapshot, modelContext: modelContext, subscribe: false)
                result.feedsProcessed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failedFeedURLs.append(feedURLString)
            }
        }
        try await reloadFromStore(modelContext: modelContext)
        try reloadProgressRecords(modelContext: modelContext)
        return result
    }

    private func update(_ subscription: SubscriptionRecord, from snapshot: FeedSnapshot) -> Bool {
        var hasChanges = false
        if subscription.title != snapshot.podcast.title {
            subscription.title = snapshot.podcast.title
            hasChanges = true
        }
        if subscription.author != snapshot.podcast.author {
            subscription.author = snapshot.podcast.author
            hasChanges = true
        }
        let artworkURL = snapshot.podcast.artworkURL?.absoluteString
        if subscription.artworkURL != artworkURL {
            subscription.artworkURL = artworkURL
            hasChanges = true
        }
        if subscription.isArchived {
            subscription.isArchived = false
            hasChanges = true
        }
        return hasChanges
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

        let clampedPosition = position.clamped(to: 0...duration)
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
        let rebuilt = Self.latestProgressRecordsByEpisodeID(progressRecords)
        // Refetches usually hand back the same registered instances; rows
        // observe those directly, so the all-row revision bump is owed only
        // when an episode's indexed record actually changes identity.
        let membershipChanged = rebuilt.count != progressByEpisodeID.count
            || rebuilt.contains { episodeID, record in progressByEpisodeID[episodeID] !== record }
        progressByEpisodeID = rebuilt
        if membershipChanged {
            progressIndexRevision &+= 1
        }
    }

    private func rebuildLatestRefreshLogByFeedURL() {
        latestRefreshLogByFeedURL = Dictionary(
            refreshLogs.map { ($0.feedURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        latestSuccessfulRefreshByFeedURL = Dictionary(
            refreshLogs.compactMap { log -> (String, Date)? in
                guard (log.errorMessage ?? "").isEmpty, let finishedAt = log.finishedAt else {
                    return nil
                }
                return (log.feedURL, finishedAt)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func recordFailure(_ error: Error) {
        let message = error.localizedDescription
        state = .failed(message)
        lastErrorMessage = message
    }
}

private struct FeedRefreshResult: Sendable {
    var feedURLString: String
    var outcome: FeedRefreshOutcome
}

private enum FeedRefreshOutcome: Sendable {
    case success(FeedFetchOutcome)
    case failure(String)
    case cancelled
}
