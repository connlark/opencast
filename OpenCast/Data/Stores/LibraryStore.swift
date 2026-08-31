import Foundation
import Observation
import OpenCastCore
import SwiftData

@Observable
final class LibraryStore {
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

    private(set) var state: State = .idle
    private(set) var subscriptions: [SubscriptionRecord] = []
    private(set) var episodes: [EpisodeListItemSnapshot] = []
    var progressRecords: [EpisodeProgressRecord] {
        progressIndex.records
    }
    /// Per-feed refresh-log projection (latest log per feed, plus its latest
    /// success), newest first. Full history: `loadAllRefreshLogs()`.
    private(set) var refreshLogs: [RefreshLogSnapshot] = []
    var refreshingFeedURLs: Set<String> {
        Set(refreshingFeedURLCounts.keys)
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
    @ObservationIgnored let localCache: any LocalLibraryCacheStore
    @ObservationIgnored private let savePlaybackSkipSettingsModelContext: (ModelContext) throws -> Void
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
    // Deliberately survives resetAfterDataNuke — observed session-scoped
    // behavior, decision deferred.
    @ObservationIgnored private var relocationAdvisor = FeedRelocationAdvisor()
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var episodeIndexByID: [String: Int] = [:]
    @ObservationIgnored private var episodeIndicesByPodcastID: [String: [Int]] = [:]
    /// O(1) search-session invalidation token. Every publication that changes
    /// `episodes` rebuilds the lookup indexes and advances this revision.
    private(set) var episodeSearchCorpusRevision = 0
    // Existing rows observe their SwiftData model directly. This revision is
    // reserved for index membership changes and out-of-band store reloads.
    private var progressIndexRevision = 0
    @ObservationIgnored private var progressIndex = EpisodeProgressIndex()
    @ObservationIgnored var pendingCacheWriteTask: Task<Void, Never>?
    @ObservationIgnored private var episodeSearchIndexPreparationTask: Task<Void, Never>?
    // Resolved artwork previews live beside `episodes`, not inside it: writing
    // episodes[index] republishes the whole array and re-diffs every List that
    // reads it — once per newly realized row during a scroll.
    var artworkPreviewOverridesByEpisodeID: [String: ArtworkPreview] = [:]

    init(
        feedService: any FeedService = DefaultFeedService(),
        localCache: any LocalLibraryCacheStore,
        savePlaybackSkipSettingsModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.feedService = feedService
        self.localCache = localCache
        self.savePlaybackSkipSettingsModelContext = savePlaybackSkipSettingsModelContext
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
                let fetchedProgressRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
                progressRecordsChanged = !EpisodeProgressIndex.records(
                    progressRecords,
                    match: fetchedProgressRecords
                )
                if progressRecordsChanged, progressIndex.replaceAll(fetchedProgressRecords) {
                    progressIndexRevision &+= 1
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
        // Mark the feed busy before the first suspension so refreshAllIfStale
        // cannot start a duplicate refresh while this one is in flight.
        beginRefreshing([feedURL])
        defer {
            endRefreshing([feedURL])
        }
        await performRefreshFlow(setsRefreshingState: false, modelContext: modelContext) { generation in
            guard let subscription = try activeSubscription(feedURL: feedURL, modelContext: modelContext) else {
                return false
            }

            try await refresh(subscription: subscription, generation: generation, modelContext: modelContext)
            return true
        }
    }

    func refreshAll(modelContext: ModelContext) async {
        let didComplete = await performRefreshFlow(setsRefreshingState: true, modelContext: modelContext) { generation in
            // The refresh set only needs the active feed URLs; the trailing
            // reload applies results, so a leading full-library reload would
            // pay the whole SQLite materialization for a subscription fetch.
            let feedURLStrings = try modelContext.fetch(activeSubscriptionsDescriptor()).map(\.feedURL)
            try await refreshAll(
                feedURLStrings: feedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            return true
        }
        if didComplete {
            refreshCompletedToken += 1
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

        await performRefreshFlow(setsRefreshingState: true, modelContext: modelContext) { generation in
            try await refreshAll(
                feedURLStrings: staleFeedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            return true
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

        return await performRefreshFlow(setsRefreshingState: true, modelContext: modelContext) { generation in
            try await refreshAll(
                feedURLStrings: feedURLStrings,
                generation: generation,
                modelContext: modelContext
            )
            return true
        }
    }

    /// The shared refresh-flow shell: generation capture, refreshing/idle
    /// state transitions, the trailing store reload, and the
    /// cancellation-is-not-an-error contract. Bulk flows set the observable
    /// refreshing state; the single-feed flow relies on per-feed markers and
    /// leaves a concurrently running bulk flow's state untouched. A `false`
    /// from `work` skips the trailing reload (nothing was fetched). Returns
    /// true only when the flow ran to full success.
    @discardableResult
    private func performRefreshFlow(
        setsRefreshingState: Bool,
        modelContext: ModelContext,
        _ work: (_ generation: Int) async throws -> Bool
    ) async -> Bool {
        let generation = writeGeneration
        if setsRefreshingState {
            state = .refreshing
        }
        lastErrorMessage = nil
        do {
            guard try await work(generation) else {
                if state != .refreshing {
                    state = .idle
                }
                return false
            }
            try await reloadFromStore(modelContext: modelContext)
            if setsRefreshingState || state != .refreshing {
                state = .idle
            }
            return true
        } catch is CancellationError {
            try? await reloadFromStore(modelContext: modelContext)
            if setsRefreshingState || state != .refreshing {
                state = .idle
            }
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
            try savePlaybackSkipSettingsModelContext(modelContext)
            syncedStoreSelfSaveCount += 1
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
        episodeSearchIndexPreparationTask?.cancel()
        episodeSearchIndexPreparationTask = nil
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
        progressIndex = EpisodeProgressIndex()
        refreshLogs.removeAll()
        clearAllRefreshMarkers()
        activePodcastIDs.removeAll()
        visibleEpisodeIDs.removeAll()
        podcastCacheByFeedURL.removeAll()
        artworkPreviewOverridesByEpisodeID.removeAll()
        lastSyncedProgressProbe = nil
        // Derived indexes rebuild from the now-empty sources.
        rebuildEpisodeIndexes()
        rebuildLatestRefreshLogByFeedURL()
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

        return EpisodeProgressRules.smartResumePosition(
            position: progress.position,
            updatedAt: progress.updatedAt,
            now: .now
        )
    }

    func progressRecord(for episodeID: String) -> EpisodeProgressRecord? {
        _ = progressIndexRevision
        return progressIndex.latest(for: episodeID)
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
            let targetPodcastID = podcastID
            let storedRecords = try modelContext.fetch(
                FetchDescriptor<EpisodeProgressRecord>(
                    predicate: #Predicate { record in
                        record.podcastID == targetPodcastID
                    }
                )
            )
            let latestRecordByEpisodeID = EpisodeProgressIndex.latestRecordsByEpisodeID(storedRecords)

            let updatedAt = Date.now
            var hasChanges = false
            for episode in podcastEpisodes {
                let duration = sanitizedDuration(episode.duration)
                let position = duration ?? 0
                if let record = latestRecordByEpisodeID[episode.episodeID] {
                    guard EpisodeProgressRules.hasMeaningfulProgressChange(
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
            if progressIndex.replaceAll(try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())) {
                progressIndexRevision &+= 1
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
            let updatedRecord: EpisodeProgressRecord
            if let existing = try progressRecord(
                episodeID: episodeID,
                podcastID: podcastID,
                modelContext: modelContext
            ) {
                guard EpisodeProgressRules.hasMeaningfulProgressChange(
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
            if refreshObservableProgress, progressIndex.apply(updatedRecord) {
                progressIndexRevision &+= 1
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
            // Archived subscriptions still mark a show as deliberately kept;
            // only shows with no subscription record at all are candidates.
            let subscribedFeedURLs = Set(
                try modelContext.fetch(FetchDescriptor<SubscriptionRecord>()).map(\.feedURL)
            )
            let prunableRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
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
        let startedAt = Date.now
        let result = await FeedRefreshFetcher.fetchResult(
            feedURLString: subscription.feedURL,
            feedService: feedService,
            localCache: localCache
        )
        try Task.checkCancellation()
        try ensureCurrentGeneration(generation)
        try await applyRefreshResult(
            result,
            startedAt: startedAt,
            generation: generation,
            modelContext: modelContext
        )
    }

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

        try await FeedRefreshFetcher.forEachResult(
            feedURLStrings: feedURLStrings,
            feedService: feedService,
            localCache: localCache
        ) { fetchResult in
            try Task.checkCancellation()
            try self.ensureCurrentGeneration(generation)
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
                    _ = try await self.upsert(snapshot: snapshot, modelContext: modelContext, subscribe: true)
                    await self.persistValidators(outcome.validators, forPodcastID: snapshot.podcast.id.rawValue)
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

        try await FeedRefreshFetcher.forEachResult(
            feedURLStrings: feedURLStrings,
            feedService: feedService,
            localCache: localCache
        ) { result in
            try Task.checkCancellation()
            try self.ensureCurrentGeneration(generation)
            pendingFeedURLStrings.remove(result.feedURLString)
            defer {
                self.endRefreshing([result.feedURLString])
            }
            try await self.applyRefreshResult(
                result,
                startedAt: startedAt,
                generation: generation,
                modelContext: modelContext
            )
        }
    }

    private func applyRefreshResult(
        _ result: FeedRefreshFetcher.Result,
        startedAt: Date,
        generation: Int,
        modelContext: ModelContext
    ) async throws {
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
        if progressIndex.replaceAll(try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())) {
            progressIndexRevision &+= 1
        }
        episodes = cacheSnapshot.episodes
        visibleEpisodeIDs = Set(cacheSnapshot.episodes.map(\.episodeID))
        podcastCacheByFeedURL = cacheSnapshot.podcastsByFeedURL
        refreshLogs = cacheSnapshot.refreshLogs
        rebuildEpisodeIndexes()
        rebuildLatestRefreshLogByFeedURL()
        prepareEpisodeSearchIndexIfNeeded()
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
        let fetchedProgressRecords = try modelContext.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        guard !EpisodeProgressIndex.records(
            progressRecords,
            match: fetchedProgressRecords
        ) else {
            return
        }

        if progressIndex.replaceAll(fetchedProgressRecords) {
            progressIndexRevision &+= 1
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

        try EpisodeIdentityMigrationApplier.apply(
            matches,
            canonicalFeedURL: canonicalFeedURL,
            sidecarMigrators: episodeSidecarMigrators,
            modelContext: modelContext
        )
        try modelContext.save()
        syncedStoreSelfSaveCount += 1
        try await localCache.deleteEpisodes(episodeIDs: matches.map(\.departedEpisodeID))
        return matches.count
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
        switch relocationAdvisor.recordRedirect(feedURLString: feedURLString, finalURL: finalURL) {
        case .clearSuggestion:
            if suggestedFeedMigrationURLsByFeedURL[feedURLString] != nil {
                suggestedFeedMigrationURLsByFeedURL[feedURLString] = nil
            }
        case .none:
            break
        case .suggest(let migrationURL):
            suggestedFeedMigrationURLsByFeedURL[feedURLString] = migrationURL
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
              relocationAdvisor.shouldProbeHTTPSUpgrade(feedURLString)
        else {
            return
        }

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
        try EpisodeIdentityMigrationApplier.apply(
            matches,
            canonicalFeedURL: newCanonicalFeedURL,
            sidecarMigrators: episodeSidecarMigrators,
            modelContext: modelContext
        )

        let deletedAt = Date.now
        modelContext.insert(
            SyncTombstoneRecord(scope: .subscription, feedURL: oldCanonicalFeedURL, deletedAt: deletedAt)
        )
        let hasNewSubscription = allSubscriptions.contains { record in
            URLCanonicalizer.canonicalString(forRawString: record.feedURL) == newCanonicalFeedURL
        }
        let migrationSkipSettings = PodcastPlaybackSkipSettings.greatestValid(
            in: oldSubscriptionRecords.map {
                PodcastPlaybackSkipSettings(
                    skipIntroSeconds: $0.skipIntroSeconds,
                    skipOutroSeconds: $0.skipOutroSeconds
                )
            }
        )
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
                    isAdAutoDetectEnabled: template.isAdAutoDetectEnabled,
                    isTranscriptAnalysisEnabled: template.isTranscriptAnalysisEnabled,
                    skipIntroSeconds: migrationSkipSettings.skipIntroSeconds,
                    skipOutroSeconds: migrationSkipSettings.skipOutroSeconds
                )
            )
        } else {
            for record in allSubscriptions where
                URLCanonicalizer.canonicalString(forRawString: record.feedURL) == newCanonicalFeedURL
            {
                Self.mergePodcastPlaybackSkipSettings(
                    migrationSkipSettings,
                    into: record
                )
            }
        }
        for record in oldSubscriptionRecords {
            modelContext.delete(record)
        }
        try modelContext.save()
        syncedStoreSelfSaveCount += 1

        try await localCache.deleteCache(forPodcastID: oldCanonicalFeedURL)
        relocationAdvisor.clearDivergence(oldFeedURLString)
        if suggestedFeedMigrationURLsByFeedURL[oldFeedURLString] != nil {
            suggestedFeedMigrationURLsByFeedURL[oldFeedURLString] = nil
        }
        try await reloadFromStore(modelContext: modelContext)
        try reloadProgressRecords(modelContext: modelContext)
    }

    @discardableResult
    static func mergePodcastPlaybackSkipSettings(
        _ incoming: PodcastPlaybackSkipSettings,
        into record: SubscriptionRecord
    ) -> Bool {
        let current = PodcastPlaybackSkipSettings(
            skipIntroSeconds: record.skipIntroSeconds,
            skipOutroSeconds: record.skipOutroSeconds
        )
        let merged = current.mergingGreatestValid(with: incoming)
        var changed = false
        if record.skipIntroSeconds != merged.skipIntroSeconds {
            record.skipIntroSeconds = merged.skipIntroSeconds
            changed = true
        }
        if record.skipOutroSeconds != merged.skipOutroSeconds {
            record.skipOutroSeconds = merged.skipOutroSeconds
            changed = true
        }
        return changed
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

    private func recordFailure(_ error: Error) {
        let message = error.localizedDescription
        state = .failed(message)
        lastErrorMessage = message
    }
}
