import Foundation
import Observation
import OpenCastCore
import OSLog
import SwiftData

@Observable
final class LibraryStore {
    /// Background/derived-data failures log here instead of writing
    /// `lastErrorMessage`, which the root presents as a modal alert and is
    /// reserved for user-initiated library operations.
    nonisolated static let backgroundFailureLogger = Logger(
        subsystem: "com.connor.opencast",
        category: "LibraryStore"
    )

    static let refreshLogRetentionLimit = 50
    static let foregroundRefreshInterval: TimeInterval = 60 * 60

    // Forwarders for the progress rules' established call sites.
    static let trivialProgressPrunableMinAge = EpisodeProgressRules.trivialProgressPrunableMinAge

    static func isPlayed(position: TimeInterval, duration: TimeInterval?) -> Bool {
        EpisodeProgressRules.isPlayed(position: position, duration: duration)
    }

    static func smartResumePosition(
        position: TimeInterval,
        updatedAt: Date,
        now: Date
    ) -> TimeInterval {
        EpisodeProgressRules.smartResumePosition(position: position, updatedAt: updatedAt, now: now)
    }

    enum State: Equatable {
        case idle
        case loading
        case refreshing
        case failed(String)
    }

    /// Written by this store's own flows and by `FeedRefreshCoordinator`'s
    /// flow shell; nothing else assigns it.
    var state: State = .idle
    private(set) var subscriptions: [SubscriptionRecord] = []
    private(set) var episodes: [EpisodeListItemSnapshot] = []
    var progressRecords: [EpisodeProgressRecord] {
        progressWriter.records
    }
    /// Per-feed refresh-log projection (latest log per feed, plus its latest
    /// success), newest first. Full history: `loadAllRefreshLogs()`.
    private(set) var refreshLogs: [RefreshLogSnapshot] = []
    var refreshingFeedURLs: Set<String> {
        feedRefreshes.refreshingFeedURLs
    }
    private(set) var activePodcastIDs: Set<String> = []
    private(set) var visibleEpisodeIDs: Set<String> = []
    // The artwork-preview extension writes the podcast cache map and reports
    // failures into lastErrorMessage, so their setters are module-visible.
    var podcastCacheByFeedURL: [String: PodcastCacheSnapshot] = [:]
    private(set) var latestRefreshLogByFeedURL: [String: RefreshLogSnapshot] = [:]
    private(set) var latestSuccessfulRefreshByFeedURL: [String: Date] = [:]
    var lastErrorMessage: String?
    private(set) var subscriptionAddedToken = 0
    var refreshCompletedToken: Int {
        feedRefreshes.refreshCompletedToken
    }

    /// Counts the app's own synced-store saves so the remote-change observer
    /// can skip the reload each one would otherwise trigger (one credit per
    /// save; see `SyncedStoreRemoteChangeArbiter`).
    var syncedStoreSelfSaveCount: Int {
        syncedStoreSelfSaveLedger.count
    }
    @ObservationIgnored private let syncedStoreSelfSaveLedger: SyncedStoreSelfSaveLedger
    /// Owns the synced progress table's writes and its published projection.
    @ObservationIgnored private let progressWriter: EpisodeProgressWriter
    @ObservationIgnored private var hasPrunedTrivialProgressThisLaunch = false
    @ObservationIgnored private var lastSyncedProgressProbe: SyncedProgressProbe?
    /// Times the synced-reload probe skipped the full progress refetch. Test hook.
    @ObservationIgnored private(set) var syncedProgressProbeSkipCount = 0

    @ObservationIgnored private let feedService: any FeedService
    @ObservationIgnored let localCache: any LocalLibraryCacheStore
    /// Episode-keyed device-local stores that identity reconciliation
    /// carries across an ID change; wired by OpenCastAppModel at composition.
    var episodeSidecarMigrators: [any EpisodeIdentitySidecarMigrating] {
        get { feedWrites.sidecarMigrators }
        set { feedWrites.sidecarMigrators = newValue }
    }

    /// Feeds offered an "Update Feed Address" suggestion; see
    /// `FeedWriteCoordinator`.
    var suggestedFeedMigrationURLsByFeedURL: [String: URL] {
        feedWrites.suggestedFeedMigrationURLsByFeedURL
    }

    /// Server-reported notification poll health per accepted feed, replaced
    /// wholesale from each successful subscription sync. Advisory UI only.
    private(set) var notificationFeedHealthByFeedURL: [String: NotificationFeedHealth] = [:]
    /// The one nuke-invalidation token; every flow that captures or checks a
    /// generation shares this instance by reference.
    @ObservationIgnored private let writeGeneration: LibraryWriteGeneration
    /// The feed-write path shared by the user add flows and the refresh flow.
    @ObservationIgnored private let feedWrites: FeedWriteCoordinator
    /// The refresh flows; lazy because they hold this store as their host.
    @ObservationIgnored private lazy var feedRefreshes = FeedRefreshCoordinator(
        host: self,
        feedService: feedService,
        localCache: localCache,
        feedWrites: feedWrites,
        writeGeneration: writeGeneration
    )
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var refreshLogReloadGeneration = 0
    @ObservationIgnored private var episodeIndexByID: [String: Int] = [:]
    @ObservationIgnored private var episodeIndicesByPodcastID: [String: [Int]] = [:]
    /// O(1) search-session invalidation token. Every publication that changes
    /// `episodes` rebuilds the lookup indexes and advances this revision.
    private(set) var episodeSearchCorpusRevision = 0
    @ObservationIgnored var pendingCacheWriteTask: Task<Void, Never>?
    @ObservationIgnored private var episodeSearchIndexPreparationTask: Task<Void, Never>?
    // Resolved artwork previews live beside `episodes`, not inside it: writing
    // episodes[index] republishes the whole array and re-diffs every List that
    // reads it — once per newly realized row during a scroll. The maps hold
    // per-key observable boxes so one row's resolution invalidates only that
    // episode's or feed's appearances, not every mounted row.
    @ObservationIgnored var artworkPreviewOverridesByEpisodeID: [String: ArtworkPreviewOverride] = [:]
    @ObservationIgnored var artworkPreviewOverridesByFeedURL: [String: ArtworkPreviewOverride] = [:]

    /// `savePlaybackSkipSettingsModelContext` is the test seam for every
    /// synced-store save, not only the skip-settings one it was named for.
    init(
        feedService: any FeedService = DefaultFeedService(),
        localCache: any LocalLibraryCacheStore,
        savePlaybackSkipSettingsModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.feedService = feedService
        self.localCache = localCache
        let ledger = SyncedStoreSelfSaveLedger(performSave: savePlaybackSkipSettingsModelContext)
        let writeGeneration = LibraryWriteGeneration()
        let progressWriter = EpisodeProgressWriter(ledger: ledger)
        let feedWrites = FeedWriteCoordinator(
            feedService: feedService,
            localCache: localCache,
            ledger: ledger,
            writeGeneration: writeGeneration
        )
        syncedStoreSelfSaveLedger = ledger
        self.writeGeneration = writeGeneration
        self.progressWriter = progressWriter
        self.feedWrites = feedWrites
        feedWrites.reloadLibrary = { [weak self] modelContext in
            guard let self else {
                return
            }
            try await reloadFromStore(modelContext: modelContext)
        }
        feedWrites.reloadProgress = { modelContext in
            _ = try progressWriter.reloadIfChanged(modelContext: modelContext)
        }
    }

    /// Synced-store saves that originate outside this store (the data nuke's
    /// row wipe) still go through the ledger so they carry their credit.
    func saveSyncedStore(_ modelContext: ModelContext) throws {
        try syncedStoreSelfSaveLedger.save(modelContext)
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

    @discardableResult
    func load(modelContext: ModelContext) async -> Bool {
        state = .loading
        lastErrorMessage = nil
        await importLegacyCacheIfNeeded(modelContext: modelContext)
        let didLoad: Bool
        do {
            try await reloadFromStore(modelContext: modelContext)
            state = .idle
            didLoad = true
        } catch {
            recordFailure(error)
            didLoad = false
        }
        // Advisory notification poll health; absence is just "no data".
        notificationFeedHealthByFeedURL = (try? await localCache.notificationFeedHealthByFeedURL()) ?? [:]
        return didLoad
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
                progressRecordsChanged = try progressWriter.reloadIfChanged(modelContext: modelContext)
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
        let generation = writeGeneration.capture()
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
            try writeGeneration.ensureCurrent(generation)
            _ = try await feedWrites.upsert(
                snapshot: snapshot,
                modelContext: modelContext,
                subscribe: true,
                generation: generation
            )
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
        await feedRefreshes.refresh(feedURL: feedURL, modelContext: modelContext)
    }

    func refreshAll(modelContext: ModelContext) async {
        await feedRefreshes.refreshAll(modelContext: modelContext)
    }

    func refreshAllIfStale(modelContext: ModelContext, now: Date = .now) async {
        await feedRefreshes.refreshAllIfStale(modelContext: modelContext, now: now)
    }

    @discardableResult
    func refreshFeedsNeedingLocalCache(modelContext: ModelContext) async -> Bool {
        await feedRefreshes.refreshFeedsNeedingLocalCache(modelContext: modelContext)
    }

    func unsubscribe(
        feedURL: String,
        modelContext: ModelContext,
        clearListeningHistory: Bool = false
    ) async {
        do {
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

            try syncedStoreSelfSaveLedger.save(modelContext)
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

    func podcastPlaybackSkipSettings(forPodcastID podcastID: String) -> PodcastPlaybackSkipSettings {
        guard let subscription = subscriptions.first(where: { $0.feedURL == podcastID }) else {
            return .disabled
        }
        return PodcastPlaybackSkipSettings(
            skipIntroSeconds: subscription.skipIntroSeconds,
            skipOutroSeconds: subscription.skipOutroSeconds
        ).sanitized
    }

    @discardableResult
    func setPodcastPlaybackSkipSettings(
        _ settings: PodcastPlaybackSkipSettings,
        feedURL: String,
        modelContext: ModelContext
    ) -> Bool {
        guard settings.isValid else {
            lastErrorMessage = "Intro and outro skips must be finite, nonnegative durations."
            return false
        }
        guard let subscription = subscriptions.first(where: { $0.feedURL == feedURL }) else {
            lastErrorMessage = "Unable to find this podcast subscription."
            return false
        }
        guard subscription.skipIntroSeconds != settings.skipIntroSeconds
                || subscription.skipOutroSeconds != settings.skipOutroSeconds
        else {
            lastErrorMessage = nil
            return true
        }

        let previousSkipIntroSeconds = subscription.skipIntroSeconds
        let previousSkipOutroSeconds = subscription.skipOutroSeconds
        subscription.skipIntroSeconds = settings.skipIntroSeconds
        subscription.skipOutroSeconds = settings.skipOutroSeconds

        do {
            try syncedStoreSelfSaveLedger.save(modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            subscription.skipIntroSeconds = previousSkipIntroSeconds
            subscription.skipOutroSeconds = previousSkipOutroSeconds
            modelContext.rollback()
            lastErrorMessage = "Unable to update intro and outro skips: \(error.localizedDescription)"
            return false
        }
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
            try syncedStoreSelfSaveLedger.save(modelContext)
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
            try progressWriter.reloadIfChanged(modelContext: modelContext)
        } catch {
            recordFailure(error)
        }
    }

    func repairSyncDuplicates(modelContext: ModelContext) async throws -> SyncRepairResult {
        let result = try SyncDuplicateRepairer.repair(
            modelContext: modelContext,
            claimedFeedURLsByEpisodeID: claimedFeedURLsByEpisodeID(),
            save: syncedStoreSelfSaveLedger.save
        )
        if result.hasIssues {
            try await reloadFromStore(modelContext: modelContext)
        }
        state = .idle
        lastErrorMessage = nil
        return result
    }

    func prepareForDataNuke() {
        writeGeneration.invalidate()
        reloadGeneration += 1
        cancelEpisodeSearchIndexPreparation()
        feedRefreshes.clearAllRefreshMarkers()
    }

    func deleteAllLocalCache() async throws {
        try await localCache.deleteAllLocalCache()
    }

    /// Invalidates a second time: a flow that started between
    /// `prepareForDataNuke` and this reset captured the post-prepare
    /// generation and would otherwise run through the cache clear unchecked.
    func resetAfterDataNuke() {
        writeGeneration.invalidate()
        reloadGeneration += 1
        cancelEpisodeSearchIndexPreparation()
        state = .idle
        subscriptions.removeAll()
        episodes.removeAll()
        progressWriter.reset()
        refreshLogs.removeAll()
        feedRefreshes.clearAllRefreshMarkers()
        activePodcastIDs.removeAll()
        visibleEpisodeIDs.removeAll()
        podcastCacheByFeedURL.removeAll()
        artworkPreviewOverridesByEpisodeID.removeAll()
        artworkPreviewOverridesByFeedURL.removeAll()
        lastSyncedProgressProbe = nil
        // Derived indexes rebuild from the now-empty sources.
        rebuildEpisodeIndexes()
        rebuildLatestRefreshLogByFeedURL()
        lastErrorMessage = nil
    }

    // Both lookups read the tracked `episodes` array before consulting the
    // ignored indexes, so a miss still registers a dependency and a body
    // that saw no episode invalidates once one appears (house guard:
    // progressRecord(for:) / DownloadStore.recordsRevision).
    func episode(with id: String) -> EpisodeListItemSnapshot? {
        let episodes = episodes
        return episodeIndexByID[id].map { episodes[$0] }
    }

    func episodes(forPodcastID podcastID: String) -> [EpisodeListItemSnapshot] {
        let episodes = episodes
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
            // Search-support fetch, retried on the next keystroke — not a
            // user-initiated operation, so it must not raise the modal alert.
            Self.backgroundFailureLogger.error(
                "Show-notes fetch failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func searchEpisodes(
        query: String,
        mode: EpisodeSearchMode,
        forPodcastID podcastID: String? = nil,
        allowedEpisodeIDs: Set<String>? = nil
    ) async -> [EpisodeSearchIndexHit]? {
        let scopedPodcastIDs: Set<String>
        if let podcastID {
            scopedPodcastIDs = activePodcastIDs.contains(podcastID)
                ? [podcastID]
                : []
        } else {
            scopedPodcastIDs = activePodcastIDs
        }
        let request = EpisodeSearchIndexRequest(
            query: query,
            mode: mode,
            activePodcastIDs: scopedPodcastIDs,
            allowedEpisodeIDs: allowedEpisodeIDs
        )
        do {
            return try await localCache.searchEpisodes(request)
        } catch {
            // Cancellation, an unready index, and store failures all share
            // the nil path: this index is disposable derived data, so the
            // session falls back to the established matcher and preparation
            // rebuilds after the cache republishes instead of surfacing an
            // unrelated library error banner.
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
        feedRefreshes.isRefreshing(feedURL: feedURL)
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

        return EpisodeProgressRules.smartResumePosition(
            position: progress.position,
            updatedAt: progress.updatedAt,
            now: .now
        )
    }

    func progressRecord(for episodeID: String) -> EpisodeProgressRecord? {
        progressWriter.latestRecord(for: episodeID)
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
            isCompleted: progress.isPlayed || EpisodeProgressRules.isPlayed(position: position, duration: duration)
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
            isPlayed: EpisodeProgressRules.isPlayed(position: position, duration: duration),
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
            guard try progressWriter.markAllPlayed(
                podcastEpisodes,
                podcastID: podcastID,
                modelContext: modelContext
            ) else {
                return false
            }
            lastErrorMessage = nil
            return true
        } catch {
            recordFailure(error)
            return false
        }
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
            return try progressWriter.update(
                episodeID: episodeID,
                podcastID: podcastID,
                position: position,
                duration: duration,
                isPlayed: isPlayed,
                modelContext: modelContext,
                refreshObservableProgress: refreshObservableProgress
            )
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
                && record.position < EpisodeProgressRules.trivialProgressPrunableMaxPosition
                && now.timeIntervalSince(record.updatedAt) > EpisodeProgressRules.trivialProgressPrunableMinAge
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
            return try progressWriter.deleteUnsubscribedRecords(
                modelContext: modelContext,
                writingTombstonesAt: tombstoneDate,
                matching: isPrunable
            )
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
            return try progressWriter.clear(
                episodeID: episode.episodeID,
                podcastID: episode.podcastID,
                modelContext: modelContext
            )
        } catch {
            recordFailure(error)
            return false
        }
    }

    /// OPML import's bulk subscribe: fetches run at the shared width while
    /// each subscription applies serially on the main actor. Per-feed
    /// failures accumulate; cancellation aborts the whole batch.
    func subscribeBatch(
        to feedURLStrings: [String],
        modelContext: ModelContext
    ) async throws -> BatchSubscribeResult {
        let generation = writeGeneration.capture()
        var result = BatchSubscribeResult()
        guard !feedURLStrings.isEmpty else {
            return result
        }

        try await FeedRefreshFetcher.forEachResult(
            feedURLStrings: feedURLStrings,
            feedService: feedService,
            localCache: localCache
        ) { fetchResult in
            try Task.checkCancellation()
            try self.writeGeneration.ensureCurrent(generation)
            switch fetchResult.outcome {
            case .success(let outcome):
                guard let snapshot = outcome.snapshot else {
                    result.failures.append(
                        BatchSubscribeFailure(
                            feedURLString: fetchResult.feedURLString,
                            message: OpenCastCoreError.invalidHTTPResponse.localizedDescription
                        )
                    )
                    return
                }
                do {
                    _ = try await self.feedWrites.upsert(
                        snapshot: snapshot,
                        modelContext: modelContext,
                        subscribe: true,
                        generation: generation
                    )
                    await self.feedRefreshes.persistValidators(outcome.validators, forPodcastID: snapshot.podcast.id.rawValue)
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

        return result
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

    func reloadFromStore(modelContext: ModelContext) async throws {
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
        try progressWriter.reload(modelContext: modelContext)
        episodes = cacheSnapshot.episodes
        visibleEpisodeIDs = Set(cacheSnapshot.episodes.map(\.episodeID))
        podcastCacheByFeedURL = cacheSnapshot.podcastsByFeedURL
        refreshLogs = cacheSnapshot.refreshLogs
        rebuildEpisodeIndexes()
        rebuildLatestRefreshLogByFeedURL()
        prepareEpisodeSearchIndexIfNeeded()
    }

    /// Scoped republication for a single-feed refresh that changed no feed
    /// content: only the refresh-log projection is reloaded, skipping the
    /// full episode materialization, the progress refetch, and the index
    /// rebuilds. A concurrent full reload owns the logs too, so this
    /// publication is abandoned when either generation moves.
    func reloadRefreshLogsFromStore() async throws {
        refreshLogReloadGeneration += 1
        let logGeneration = refreshLogReloadGeneration
        let fullGeneration = reloadGeneration

        let cacheSnapshot = try await localCache.loadLibrary(activePodcastIDs: [])

        guard logGeneration == refreshLogReloadGeneration,
              fullGeneration == reloadGeneration
        else {
            return
        }

        refreshLogs = cacheSnapshot.refreshLogs
        rebuildLatestRefreshLogByFeedURL()
    }

    private func cancelEpisodeSearchIndexPreparation() {
        episodeSearchIndexPreparationTask?.cancel()
        episodeSearchIndexPreparationTask = nil
    }

    private func prepareEpisodeSearchIndexIfNeeded() {
        guard !SearchColdStartProbe.disablesSearchIndexPreparation else {
            return
        }
        guard episodeSearchIndexPreparationTask == nil else {
            return
        }
        let localCache = localCache
        episodeSearchIndexPreparationTask = Task { [weak self] in
            do {
                try await localCache.prepareEpisodeSearchIndex()
            } catch is CancellationError {
                // Cancellation is normal during teardown or a data reset.
            } catch {
                // The lexical index is derived; search keeps using its
                // established fallback and a later load retries the rebuild.
            }
            self?.episodeSearchIndexPreparationTask = nil
        }
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

    func activeSubscription(
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

    /// The bulk refresh set, in the store's display order.
    func activeSubscriptionFeedURLStrings(modelContext: ModelContext) throws -> [String] {
        try modelContext.fetch(activeSubscriptionsDescriptor()).map(\.feedURL)
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
                  lhsRecord.isAdAutoDetectEnabled == rhsRecord.isAdAutoDetectEnabled,
                  lhsRecord.isTranscriptAnalysisEnabled == rhsRecord.isTranscriptAnalysisEnabled,
                  lhsRecord.skipIntroSeconds == rhsRecord.skipIntroSeconds,
                  lhsRecord.skipOutroSeconds == rhsRecord.skipOutroSeconds
            else {
                return false
            }
        }

        return true
    }

    /// Moves a subscription onto a new canonical feed URL; see
    /// `FeedWriteCoordinator.migrateSubscription`.
    func migrateSubscription(
        from oldFeedURLString: String,
        toFeedURL newFeedURL: URL,
        modelContext: ModelContext
    ) async throws {
        try await feedWrites.migrateSubscription(
            from: oldFeedURLString,
            toFeedURL: newFeedURL,
            modelContext: modelContext
        )
    }

    /// Diagnostics sweep for libraries duplicated before reconciliation
    /// existed; see `FeedWriteCoordinator.mergeDuplicateEpisodes`.
    func mergeDuplicateEpisodes(modelContext: ModelContext) async throws -> EpisodeMergeResult {
        try await feedWrites.mergeDuplicateEpisodes(
            feedURLStrings: subscriptions.map(\.feedURL),
            modelContext: modelContext
        )
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
        episodeSearchCorpusRevision &+= 1
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

    func recordFailure(_ error: any Error) {
        let message = error.localizedDescription
        state = .failed(message)
        lastErrorMessage = message
    }
}

extension LibraryStore: FeedRefreshHost {}
