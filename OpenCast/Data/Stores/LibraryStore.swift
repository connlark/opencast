import Foundation
import Observation
import OpenCastCore
import OSLog
import SwiftData

@Observable
final class LibraryStore {
    /// For background and derived-data failures: `lastErrorMessage` shows a modal alert and is
    /// reserved for user-initiated library operations.
    nonisolated static let backgroundFailureLogger = Logger(
        subsystem: "com.connor.opencast",
        category: "LibraryStore"
    )

    static let refreshLogRetentionLimit = 50
    static let foregroundRefreshInterval: TimeInterval = 60 * 60
    static let episodeSummaryMaximumCharacters = 2_000

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

    /// Assigned only by this store and `FeedRefreshCoordinator`.
    var state: State = .idle
    private(set) var subscriptions: [SubscriptionRecord] = []
    /// `EpisodeListItemSnapshot.newestFirst` order, ties by ascending episode ID. Smart playlists
    /// rely on this order to stop at a limit.
    private(set) var episodes: [EpisodeListItemSnapshot] = []
    var progressRecords: [EpisodeProgressRecord] {
        progressWriter.records
    }
    /// The latest log per feed, plus its latest success, newest first; not the full history.
    private(set) var refreshLogs: [RefreshLogSnapshot] = []
    private(set) var incompleteFeeds: [String: FeedIncompleteReason] = [:]
    private var processingRefreshPodcastIDs: Set<String> = []
    private(set) var automaticRetryAfterByFeedURL: [String: Date] = [:]
    var refreshingFeedURLs: Set<String> {
        feedRefreshes.refreshingFeedURLs
    }
    private(set) var activePodcastIDs: Set<String> = []
    private(set) var visibleEpisodeIDs: Set<String> = []
    var podcastCacheByFeedURL: [String: PodcastCacheSnapshot] = [:]
    private(set) var latestRefreshLogByFeedURL: [String: RefreshLogSnapshot] = [:]
    private(set) var latestSuccessfulRefreshByFeedURL: [String: Date] = [:]
    private var latestEpisodeContentChangeByFeedURL: [String: Date] = [:]
    var lastErrorMessage: String?
    private(set) var subscriptionAddedToken = 0
    var refreshCompletedToken: Int {
        feedRefreshes.refreshCompletedToken
    }
    var contentRefreshToken: Int {
        feedRefreshes.contentRefreshToken
    }
    var lastRefreshWasOffline: Bool {
        feedRefreshes.lastRefreshWasOffline
    }

    var syncedStoreSelfSaveCount: Int {
        syncedStoreSelfSaveLedger.count
    }
    @ObservationIgnored private let syncedStoreSelfSaveLedger: SyncedStoreSelfSaveLedger
    /// Owns the synced progress table's writes and its published projection.
    @ObservationIgnored private let progressWriter: EpisodeProgressWriter
    @ObservationIgnored private var hasPrunedTrivialProgressThisLaunch = false
    @ObservationIgnored private var lastSyncedProgressProbe: SyncedProgressProbe?
    @ObservationIgnored private(set) var syncedProgressProbeSkipCount = 0

    @ObservationIgnored private let feedService: any FeedService
    @ObservationIgnored let localCache: any LocalLibraryCacheStore
    @ObservationIgnored private let now: () -> Date
    var episodeSidecarMigrators: [any EpisodeIdentitySidecarMigrating] {
        get { feedWrites.sidecarMigrators }
        set { feedWrites.sidecarMigrators = newValue }
    }

    var suggestedFeedMigrationURLsByFeedURL: [String: URL] {
        feedWrites.suggestedFeedMigrationURLsByFeedURL
    }

    private(set) var notificationFeedHealthByFeedURL: [String: NotificationFeedHealth] = [:]
    /// The one nuke-invalidation token, shared by reference with every write flow.
    @ObservationIgnored private let writeGeneration: LibraryWriteGeneration
    @ObservationIgnored private let feedWrites: FeedWriteCoordinator
    @ObservationIgnored private lazy var feedRefreshes = FeedRefreshCoordinator(
        host: self,
        feedService: feedService,
        localCache: localCache,
        feedWrites: feedWrites,
        writeGeneration: writeGeneration,
        now: now
    )
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private let reloadCompletion = LibraryReloadCompletion()
    @ObservationIgnored private var refreshLogReloadGeneration = 0
    @ObservationIgnored private var episodeIndexByID: [String: Int] = [:]
    @ObservationIgnored private var episodeIndicesByPodcastID: [String: [Int]] = [:]
    @ObservationIgnored private(set) var episodeReleaseOrderByPodcastID: [String: [Int]] = [:]
    /// Moves at library publication, Library entry and scene activation, never on a timer, so
    /// time-based badge changes land only at those checkpoints.
    private(set) var newEpisodeReferenceDate: Date
    /// Advances after every full progress refetch: a refetch updates a held row's values without an
    /// Observation notification, and `EpisodeProgressWriter.revision` tracks only index membership.
    private(set) var progressRefetchRevision = 0
    /// Moves whenever a played-state filter may read a different answer. Each counter only
    /// increases, so the sum moves whenever any does.
    var progressChangeRevision: Int {
        progressWriter.statusRevision &+ progressWriter.revision &+ progressRefetchRevision
    }
    /// Copied out of the records so a synced reload can compare values: a refetch updates a live
    /// record's `subscribedAt` without notifying Observation, and records compare by reference.
    private(set) var newEpisodeCutoffByFeedURL: [String: Date] = [:]
    /// Advances with every publication that changes `episodes`.
    private(set) var episodeSearchCorpusRevision = 0
    @ObservationIgnored var pendingCacheWriteTask: Task<Void, Never>?
    @ObservationIgnored private var episodeSearchIndexPreparationTask: Task<Void, Never>?
    // Kept beside `episodes`, not in it: writing episodes[index] republishes the array and re-diffs
    // every List that reads it, once per realized row during a scroll. Per-key observable boxes
    // invalidate only that episode's or feed's rows.
    @ObservationIgnored var artworkPreviewOverridesByEpisodeID: [String: ArtworkPreviewOverride] = [:]
    @ObservationIgnored var artworkPreviewOverridesByFeedURL: [String: ArtworkPreviewOverride] = [:]

    /// `savePlaybackSkipSettingsModelContext` performs every synced-store save, despite its name.
    init(
        feedService: any FeedService = DefaultFeedService(),
        localCache: any LocalLibraryCacheStore,
        savePlaybackSkipSettingsModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
        now: @escaping () -> Date = { .now }
    ) {
        self.feedService = feedService
        self.localCache = localCache
        self.now = now
        newEpisodeReferenceDate = now()
        let ledger = SyncedStoreSelfSaveLedger(performSave: savePlaybackSkipSettingsModelContext)
        let writeGeneration = LibraryWriteGeneration()
        let progressWriter = EpisodeProgressWriter(ledger: ledger)
        let feedWrites = FeedWriteCoordinator(
            feedService: feedService,
            localCache: localCache,
            ledger: ledger,
            writeGeneration: writeGeneration,
            now: now
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

    /// Synced-store saves from outside this store go through here so they carry a self-save credit.
    func saveSyncedStore(_ modelContext: ModelContext) throws {
        try syncedStoreSelfSaveLedger.save(modelContext)
    }

    var inboxEpisodes: [EpisodeListItemSnapshot] {
        episodes
    }

    /// One per feed while sync twins await repair.
    var uniqueSubscriptions: [SubscriptionRecord] {
        var seenFeedURLs = Set<String>()
        return subscriptions.filter { subscription in
            seenFeedURLs.insert(subscription.feedURL).inserted
        }
    }

    var latestRefreshOverall: RefreshLogSnapshot? {
        refreshLogs.first
    }

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
            return hasPodcastCache && hasEpisodeCache && !processingRefreshPodcastIDs.contains(feedURL) ? nil : feedURL
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
        notificationFeedHealthByFeedURL = (try? await localCache.notificationFeedHealthByFeedURL()) ?? [:]
        return didLoad
    }

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

            // Progress is the large table, so a count + newest-updatedAt probe gates its refetch.
            // Subscriptions have no updatedAt to probe, and adding one is a synced-schema change.
            let progressProbe = try syncedProgressProbe(modelContext: modelContext)
            let progressRecordsChanged: Bool
            if progressProbe == lastSyncedProgressProbe {
                syncedProgressProbeSkipCount += 1
                progressRecordsChanged = false
            } else {
                progressRecordsChanged = try progressWriter.reloadIfChanged(modelContext: modelContext)
                lastSyncedProgressProbe = progressProbe
                progressRefetchRevision &+= 1
            }

            if activeSubscriptionRecordsChanged {
                subscriptions = fetchedSubscriptions
            }
            let newEpisodeCutoffs = Self.newEpisodeCutoffs(fetchedSubscriptions)
            if newEpisodeCutoffs != newEpisodeCutoffByFeedURL {
                newEpisodeCutoffByFeedURL = newEpisodeCutoffs
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
            guard let snapshot = try await feedService.prepareFeed(
                at: feedURL,
                validators: nil,
                intent: .interactive
            ).feed else {
                throw OpenCastCoreError.invalidHTTPResponse
            }
            try writeGeneration.ensureCurrent(generation)
            _ = try await feedWrites.upsert(
                prepared: snapshot,
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

    func subscribe(prepared: PreparedFeed, modelContext: ModelContext) async throws {
        let generation = writeGeneration.capture()
        state = .refreshing
        lastErrorMessage = nil
        do {
            _ = try await feedWrites.upsert(prepared: prepared, modelContext: modelContext,
                                           subscribe: true, generation: generation)
            try await reloadFromStore(modelContext: modelContext)
            state = .idle
            subscriptionAddedToken += 1
        } catch is CancellationError {
            state = .idle
            throw CancellationError()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func refresh(feedURL: String, modelContext: ModelContext) async {
        await feedRefreshes.refresh(feedURL: feedURL, modelContext: modelContext)
    }

    func requestManualRefresh(feedURL: String, modelContext: ModelContext) {
        feedRefreshes.requestManualRefresh(feedURL: feedURL, modelContext: modelContext)
    }

    func cancelManualRefresh(feedURL: String) {
        feedRefreshes.cancelManualRefresh(feedURL: feedURL)
    }

    var manualRefreshTaskCountForTesting: Int {
        feedRefreshes.manualRefreshTaskCountForTesting
    }

    var reloadWaiterCountForTesting: Int {
        reloadCompletion.waiterCount
    }

    func refreshAll(modelContext: ModelContext) async {
        await feedRefreshes.refreshAll(modelContext: modelContext)
    }

    func refreshAllIfStale(modelContext: ModelContext, now: Date = .now) async {
        await feedRefreshes.refreshAllIfStale(modelContext: modelContext, now: now)
    }

    func recoverConnectivity(
        refreshesStaleFeeds: Bool,
        modelContext: ModelContext,
        now: Date = .now,
        canRefresh: @escaping () -> Bool = { true }
    ) async {
        await feedRefreshes.recoverConnectivity(
            refreshesStaleFeeds: refreshesStaleFeeds,
            modelContext: modelContext,
            now: now,
            canRefresh: canRefresh
        )
    }

    func cancelConnectivityRecovery() {
        feedRefreshes.cancelConnectivityRecovery()
    }

    func waitForConnectivityRecoveryForTesting() async {
        await feedRefreshes.waitForConnectivityRecoveryForTesting()
    }

    @discardableResult
    func refreshFeedsNeedingLocalCache(modelContext: ModelContext, now: Date = .now) async -> Bool {
        await feedRefreshes.refreshFeedsNeedingLocalCache(modelContext: modelContext, now: now)
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
            let progressRecords = clearListeningHistory
                ? try modelContext.fetch(
                    FetchDescriptor<EpisodeProgressRecord>(
                        predicate: #Predicate { record in
                            record.podcastID == targetFeedURL
                        }
                    )
                )
                : []
            // Legacy cache rows linger until the one-time SQLite import runs; deleting them stops a
            // later import from resurrecting this feed's cache.
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

            // A local delete alone does not stick: a CloudKit copy not yet imported would resurrect
            // the feed on every device. The tombstones make the delete authoritative.
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

    func podcastPlaybackRateOverride(forPodcastID podcastID: String) -> Float? {
        subscriptions.first { $0.feedURL == podcastID }
            .flatMap { PodcastPlaybackRateOverride.resolved($0.playbackRate) }
    }

    func podcastUpNextAutoAddPosition(forPodcastID podcastID: String) -> UpNextAutoAddPosition? {
        subscriptions.first { $0.feedURL == podcastID }
            .flatMap { UpNextAutoAddPosition(stored: $0.autoAddToUpNext) }
    }

    /// Derived on read: the setters change the records in place.
    var upNextAutoAddPodcastIDs: Set<String> {
        Set(
            subscriptions.lazy
                .filter { UpNextAutoAddPosition(stored: $0.autoAddToUpNext) != nil }
                .map(\.feedURL)
        )
    }

    @discardableResult
    func setPodcastPlaybackSettings(
        _ skipSettings: PodcastPlaybackSkipSettings,
        rateOverride: Float?,
        upNextAutoAdd: UpNextAutoAddPosition?,
        feedURL: String,
        modelContext: ModelContext
    ) -> Bool {
        guard skipSettings.isValid else {
            lastErrorMessage = "Intro and outro skips must be finite, nonnegative durations."
            return false
        }
        guard rateOverride.map(PodcastPlaybackRateOverride.isValid) ?? true else {
            lastErrorMessage = Self.invalidPlaybackRateMessage
            return false
        }
        guard let subscription = subscriptions.first(where: { $0.feedURL == feedURL }) else {
            lastErrorMessage = "Unable to find this podcast subscription."
            return false
        }
        let playbackRate = PodcastPlaybackRateOverride.stored(rateOverride)
        let changesUpNextAutoAdd = UpNextAutoAddPosition(stored: subscription.autoAddToUpNext) != upNextAutoAdd
        guard subscription.skipIntroSeconds != skipSettings.skipIntroSeconds
                || subscription.skipOutroSeconds != skipSettings.skipOutroSeconds
                || subscription.playbackRate != playbackRate
                || changesUpNextAutoAdd
        else {
            lastErrorMessage = nil
            return true
        }

        let previousSkipIntroSeconds = subscription.skipIntroSeconds
        let previousSkipOutroSeconds = subscription.skipOutroSeconds
        let previousPlaybackRate = subscription.playbackRate
        let previousAutoAddToUpNext = subscription.autoAddToUpNext
        subscription.skipIntroSeconds = skipSettings.skipIntroSeconds
        subscription.skipOutroSeconds = skipSettings.skipOutroSeconds
        subscription.playbackRate = playbackRate
        if changesUpNextAutoAdd {
            subscription.autoAddToUpNext = UpNextAutoAddPosition.stored(upNextAutoAdd)
        }

        do {
            try syncedStoreSelfSaveLedger.save(modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            subscription.skipIntroSeconds = previousSkipIntroSeconds
            subscription.skipOutroSeconds = previousSkipOutroSeconds
            subscription.playbackRate = previousPlaybackRate
            subscription.autoAddToUpNext = previousAutoAddToUpNext
            modelContext.rollback()
            lastErrorMessage = "Unable to update playback settings: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func setPodcastPlaybackRateOverride(
        _ rate: Float?,
        feedURL: String,
        modelContext: ModelContext
    ) -> Bool {
        guard rate.map(PodcastPlaybackRateOverride.isValid) ?? true else {
            lastErrorMessage = Self.invalidPlaybackRateMessage
            return false
        }
        guard let subscription = subscriptions.first(where: { $0.feedURL == feedURL }) else {
            lastErrorMessage = "Unable to find this podcast subscription."
            return false
        }
        let playbackRate = PodcastPlaybackRateOverride.stored(rate)
        guard subscription.playbackRate != playbackRate else {
            lastErrorMessage = nil
            return true
        }

        let previousPlaybackRate = subscription.playbackRate
        subscription.playbackRate = playbackRate

        do {
            try syncedStoreSelfSaveLedger.save(modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            subscription.playbackRate = previousPlaybackRate
            modelContext.rollback()
            lastErrorMessage = "Unable to update this show's speed: \(error.localizedDescription)"
            return false
        }
    }

    private static let invalidPlaybackRateMessage = "Speed must be between 0.5x and 3x."

    @discardableResult
    func setPodcastUpNextAutoAddPosition(
        _ position: UpNextAutoAddPosition?,
        feedURL: String,
        modelContext: ModelContext
    ) -> Bool {
        guard let subscription = subscriptions.first(where: { $0.feedURL == feedURL }) else {
            lastErrorMessage = "Unable to find this podcast subscription."
            return false
        }
        guard UpNextAutoAddPosition(stored: subscription.autoAddToUpNext) != position else {
            lastErrorMessage = nil
            return true
        }

        let previousAutoAddToUpNext = subscription.autoAddToUpNext
        subscription.autoAddToUpNext = UpNextAutoAddPosition.stored(position)

        do {
            try syncedStoreSelfSaveLedger.save(modelContext)
            lastErrorMessage = nil
            return true
        } catch {
            subscription.autoAddToUpNext = previousAutoAddToUpNext
            modelContext.rollback()
            lastErrorMessage = "Unable to update Add to Up Next: \(error.localizedDescription)"
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

    /// Sub-minute movement cannot change a 30-day window, so it is skipped rather than invalidating
    /// every row on each tab switch.
    func advanceNewEpisodeReferenceDate() {
        let currentDate = now()
        guard abs(currentDate.timeIntervalSince(newEpisodeReferenceDate)) >= 60 else {
            return
        }

        newEpisodeReferenceDate = currentDate
    }

    func refreshProgressRecords(modelContext: ModelContext) {
        do {
            try progressWriter.reloadIfChanged(modelContext: modelContext)
            progressRefetchRevision &+= 1
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
        reloadCompletion.invalidate(reloadGeneration)
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
        reloadCompletion.invalidate(reloadGeneration)
        cancelEpisodeSearchIndexPreparation()
        state = .idle
        subscriptions.removeAll()
        episodes.removeAll()
        progressWriter.reset()
        refreshLogs.removeAll()
        incompleteFeeds.removeAll()
        processingRefreshPodcastIDs.removeAll()
        automaticRetryAfterByFeedURL.removeAll()
        feedRefreshes.clearAllRefreshMarkers()
        activePodcastIDs.removeAll()
        visibleEpisodeIDs.removeAll()
        podcastCacheByFeedURL.removeAll()
        artworkPreviewOverridesByEpisodeID.removeAll()
        artworkPreviewOverridesByFeedURL.removeAll()
        lastSyncedProgressProbe = nil
        newEpisodeReferenceDate = now()
        newEpisodeCutoffByFeedURL.removeAll()
        rebuildEpisodeIndexes()
        rebuildLatestRefreshLogByFeedURL()
        lastErrorMessage = nil
    }

    // Both lookups read the tracked `episodes` before the ignored indexes, so a miss still
    // registers a dependency and a body that saw no episode invalidates once one appears.
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

    func episodeCount(forPodcastID podcastID: String) -> Int {
        episodeIndicesByPodcastID[podcastID]?.count ?? 0
    }

    func episodeDetail(for episodeID: String) async -> EpisodeDetailSnapshot? {
        do {
            return try await localCache.episodeDetail(episodeID: episodeID)
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

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
            Self.backgroundFailureLogger.error(
                "Show-notes fetch failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func episodeSummaries(forPodcastID podcastID: String) async -> [String: String]? {
        guard activePodcastIDs.contains(podcastID) else {
            return [:]
        }

        do {
            return try await localCache.episodeSummaries(
                forPodcastID: podcastID,
                maximumCharacters: Self.episodeSummaryMaximumCharacters
            )
        } catch {
            Self.backgroundFailureLogger.error(
                "Episode-summary fetch failed: \(error.localizedDescription, privacy: .public)"
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
            // The index is disposable derived data: every failure, cancellation and an unready
            // index included, returns nil rather than a library error.
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

    func lastContentChangedAt(for feedURL: String) -> Date? {
        [podcastCacheByFeedURL[feedURL]?.updatedAt, latestEpisodeContentChangeByFeedURL[feedURL]]
            .compactMap(\.self)
            .max()
    }

    /// The synced `lastRefreshAt` is frozen after the initial subscribe, so it only stands in for
    /// feeds this device has not refreshed.
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

    /// By each episode's latest progress row; moves on archives, unarchives and refetches alike.
    var archivedEpisodeIDs: Set<String> {
        progressWriter.archivedEpisodeIDs
    }

    func isArchived(episodeID: String) -> Bool {
        archivedEpisodeIDs.contains(episodeID)
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

    /// Deliberately narrow: played episodes and real positions are kept forever, so unsubscribe
    /// keeps its listening history.
    @discardableResult
    func pruneTrivialUnsubscribedProgressRecords(
        modelContext: ModelContext,
        now: Date = .now
    ) -> Int {
        guard !hasPrunedTrivialProgressThisLaunch else {
            return 0
        }

        hasPrunedTrivialProgressThisLaunch = true
        // No tombstones: a feed-level one would also delete the history this prune keeps. Unseen
        // copies can resurrect, but every device prunes again at launch, so the cleanup converges.
        return deleteUnsubscribedProgressRecords(
            modelContext: modelContext,
            writingTombstonesAt: nil
        ) { record in
            !record.isPlayed
                && record.position < EpisodeProgressRules.trivialProgressPrunableMaxPosition
                && now.timeIntervalSince(record.updatedAt) > EpisodeProgressRules.trivialProgressPrunableMinAge
        }
    }

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

    @discardableResult
    func archive(_ episode: EpisodeListItemSnapshot, modelContext: ModelContext) -> Bool {
        setArchived(true, episodes: [episode], modelContext: modelContext)
    }

    @discardableResult
    func archive(_ episodes: [EpisodeListItemSnapshot], modelContext: ModelContext) -> Bool {
        setArchived(true, episodes: episodes, modelContext: modelContext)
    }

    @discardableResult
    func unarchive(_ episode: EpisodeListItemSnapshot, modelContext: ModelContext) -> Bool {
        setArchived(false, episodes: [episode], modelContext: modelContext)
    }

    @discardableResult
    func unarchive(_ episodes: [EpisodeListItemSnapshot], modelContext: ModelContext) -> Bool {
        setArchived(false, episodes: episodes, modelContext: modelContext)
    }

    private func setArchived(
        _ isArchived: Bool,
        episodes: [EpisodeListItemSnapshot],
        modelContext: ModelContext
    ) -> Bool {
        let episodeIDsByPodcastID = Dictionary(grouping: episodes, by: \.podcastID)
            .mapValues { Set($0.map(\.episodeID)) }
        var didChange = false
        do {
            for podcastID in episodeIDsByPodcastID.keys.sorted() {
                let changed = try progressWriter.setArchived(
                    isArchived,
                    episodeIDs: episodeIDsByPodcastID[podcastID] ?? [],
                    podcastID: podcastID,
                    modelContext: modelContext
                )
                didChange = changed || didChange
            }
            return didChange
        } catch {
            recordFailure(error)
            return false
        }
    }

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
            localCache: localCache,
            intent: .interactive
        ) { fetchResult in
            try Task.checkCancellation()
            try self.writeGeneration.ensureCurrent(generation)
            switch fetchResult.outcome {
            case .success(let outcome):
                guard let snapshot = outcome.feed else {
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
                        prepared: snapshot,
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
            case .failure(let message), .unreachable(let message):
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
            // Must not block launch: the legacy rows stay and the next load retries.
            lastErrorMessage = error.localizedDescription
        }
    }

    func reloadFromStore(modelContext: ModelContext) async throws {
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadCompletion.begin(generation)
        do {
            try await loadAndPublishLibrary(modelContext: modelContext, generation: generation)
            reloadCompletion.finishPublished(generation)
        } catch {
            if error is CancellationError {
                reloadCompletion.finishCancelled(generation)
            } else {
                reloadCompletion.finishFailed(generation, error: error)
            }
            throw error
        }
    }

    private func loadAndPublishLibrary(modelContext: ModelContext, generation: Int) async throws {
        let cacheSnapshot = try await localCache.loadLibrary(
            activePodcastIDs: activeSubscriptionFeedURLs(modelContext: modelContext)
        )
        let indexes = try await LibraryEpisodeIndexes.prepare(cacheSnapshot.episodes)

        guard generation == reloadGeneration else {
            try await awaitPublishedReload(modelContext: modelContext)
            return
        }

        // Fetch SwiftData state after the suspension: a mutator can run while the SQLite load is in
        // flight, and publishing a pre-await fetch would resurrect deleted model objects.
        let activeSubscriptions = try modelContext.fetch(activeSubscriptionsDescriptor())
        subscriptions = activeSubscriptions
        activePodcastIDs = Set(activeSubscriptions.map(\.feedURL))
        newEpisodeCutoffByFeedURL = Self.newEpisodeCutoffs(activeSubscriptions)
        try progressWriter.reload(modelContext: modelContext)
        episodes = cacheSnapshot.episodes
        visibleEpisodeIDs = indexes.visibleIDs
        podcastCacheByFeedURL = cacheSnapshot.podcastsByFeedURL
        refreshLogs = cacheSnapshot.refreshLogs
        incompleteFeeds = cacheSnapshot.incompleteFeeds
        processingRefreshPodcastIDs = cacheSnapshot.processingRefreshPodcastIDs
        automaticRetryAfterByFeedURL = cacheSnapshot.automaticRetryAfterByFeedURL
        episodeIndexByID = indexes.byID
        episodeIndicesByPodcastID = indexes.byPodcastID
        latestEpisodeContentChangeByFeedURL = indexes.latestContentChangeByPodcastID
        episodeReleaseOrderByPodcastID = indexes.releaseOrderByPodcastID
        newEpisodeReferenceDate = now()
        episodeSearchCorpusRevision &+= 1
        rebuildLatestRefreshLogByFeedURL()
        prepareEpisodeSearchIndexIfNeeded()
    }

    private func awaitPublishedReload(modelContext: ModelContext) async throws {
        while true {
            switch try await reloadCompletion.waitForCurrent() {
            case .published:
                return
            case .invalidated:
                throw CancellationError()
            case .replacementRequired(let cancelledGeneration):
                try Task.checkCancellation()
                if reloadCompletion.claimReplacement(for: cancelledGeneration) {
                    try await reloadFromStore(modelContext: modelContext)
                    return
                }
            }
        }
    }

    /// A concurrent full reload publishes the logs too, so this publication is abandoned when
    /// either generation moves.
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
        incompleteFeeds = cacheSnapshot.incompleteFeeds
        processingRefreshPodcastIDs = cacheSnapshot.processingRefreshPodcastIDs
        automaticRetryAfterByFeedURL = cacheSnapshot.automaticRetryAfterByFeedURL
        rebuildLatestRefreshLogByFeedURL()
        prepareEpisodeSearchIndexIfNeeded()
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
            } catch {
                // Derived data: search falls back and a later load retries the rebuild.
            }
            self?.episodeSearchIndexPreparationTask = nil
        }
    }

    /// An episode ID claimed by more than one feed (audio syndicated across shows) is ambiguous and
    /// left out.
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

    /// Duplicate records for one feed take the newest follow date, the
    /// direction duplicate repair converges on.
    private static func newEpisodeCutoffs(_ subscriptions: [SubscriptionRecord]) -> [String: Date] {
        Dictionary(subscriptions.map { ($0.feedURL, $0.subscribedAt) }, uniquingKeysWith: max)
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
                  lhsRecord.skipOutroSeconds == rhsRecord.skipOutroSeconds,
                  lhsRecord.playbackRate == rhsRecord.playbackRate,
                  lhsRecord.autoAddToUpNext == rhsRecord.autoAddToUpNext
            else {
                return false
            }
        }

        return true
    }

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

    func mergeDuplicateEpisodes(modelContext: ModelContext) async throws -> EpisodeMergeResult {
        try await feedWrites.mergeDuplicateEpisodes(
            feedURLStrings: subscriptions.map(\.feedURL),
            modelContext: modelContext
        )
    }

    private func rebuildEpisodeIndexes() {
        let indexes = LibraryEpisodeIndexes(episodes: episodes)
        episodeIndexByID = indexes.byID
        episodeIndicesByPodcastID = indexes.byPodcastID
        latestEpisodeContentChangeByFeedURL = indexes.latestContentChangeByPodcastID
        episodeReleaseOrderByPodcastID = indexes.releaseOrderByPodcastID
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
