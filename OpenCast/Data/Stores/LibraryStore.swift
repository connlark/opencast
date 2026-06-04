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
    private(set) var episodes: [EpisodeCacheRecord] = []
    private(set) var progressRecords: [EpisodeProgressRecord] = []
    private(set) var refreshLogs: [RefreshLogRecord] = []
    private(set) var refreshingFeedURLs: Set<String> = []
    private(set) var activePodcastIDs: Set<String> = []
    private(set) var visibleEpisodeIDs: Set<String> = []
    private(set) var inboxEpisodes: [EpisodeCacheRecord] = []
    private(set) var podcastCacheByFeedURL: [String: PodcastCacheRecord] = [:]
    private(set) var latestRefreshLogByFeedURL: [String: RefreshLogRecord] = [:]
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let feedService: any FeedService
    @ObservationIgnored private var writeGeneration = 0

    init(feedService: any FeedService = DefaultFeedService()) {
        self.feedService = feedService
    }

    var latestRefreshOverall: RefreshLogRecord? {
        refreshLogs.first
    }

    var latestRefreshFailure: RefreshLogRecord? {
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

    func load(modelContext: ModelContext) {
        state = .loading
        lastErrorMessage = nil
        do {
            try reloadFromStore(modelContext: modelContext)
            state = .idle
        } catch {
            recordFailure(error)
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
            try upsert(snapshot: snapshot, modelContext: modelContext, subscribe: true)
            if reloadAfter {
                try reloadFromStore(modelContext: modelContext)
                state = .idle
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
        do {
            try reloadFromStore(modelContext: modelContext)
            guard let subscription = subscriptions.first(where: { $0.feedURL == feedURL }) else {
                if state != .refreshing {
                    state = .idle
                }
                return
            }

            try await refresh(subscription: subscription, generation: generation, modelContext: modelContext)
            try reloadFromStore(modelContext: modelContext)
            if state != .refreshing {
                state = .idle
            }
        } catch is CancellationError {
            try? reloadFromStore(modelContext: modelContext)
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
            try reloadFromStore(modelContext: modelContext)
            try await refreshAll(
                feedURLStrings: subscriptions.map(\.feedURL),
                generation: generation,
                modelContext: modelContext
            )
            try reloadFromStore(modelContext: modelContext)
            state = .idle
        } catch is CancellationError {
            refreshingFeedURLs.removeAll()
            try? reloadFromStore(modelContext: modelContext)
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

        do {
            try reloadFromStore(modelContext: modelContext)
            guard isForegroundRefreshDue(now: now) else {
                return
            }
        } catch {
            recordFailure(error)
            return
        }

        await refreshAll(modelContext: modelContext)
    }

    func unsubscribe(
        feedURL: String,
        modelContext: ModelContext,
        downloadStore: DownloadStore? = nil
    ) {
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
            let podcastCaches = try modelContext.fetch(
                FetchDescriptor<PodcastCacheRecord>(
                    predicate: #Predicate { record in
                        record.feedURL == targetFeedURL
                    }
                )
            )
            let episodeCaches = try modelContext.fetch(
                FetchDescriptor<EpisodeCacheRecord>(
                    predicate: #Predicate { record in
                        record.podcastID == targetFeedURL
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
            let refreshLogs = try modelContext.fetch(
                FetchDescriptor<RefreshLogRecord>(
                    predicate: #Predicate { record in
                        record.feedURL == targetFeedURL
                    }
                )
            )

            for record in subscriptions {
                modelContext.delete(record)
            }
            for record in podcastCaches {
                modelContext.delete(record)
            }
            for record in episodeCaches {
                modelContext.delete(record)
            }
            for record in progressRecords {
                modelContext.delete(record)
            }
            for record in refreshLogs {
                modelContext.delete(record)
            }

            try modelContext.save()
            try reloadFromStore(modelContext: modelContext)
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

    func repairSyncDuplicates(modelContext: ModelContext) throws -> SyncRepairResult {
        let result = try SyncDuplicateRepairer.repair(modelContext: modelContext)
        if result.hasIssues {
            try reloadFromStore(modelContext: modelContext)
        }
        state = .idle
        lastErrorMessage = nil
        return result
    }

    func prepareForDataNuke() {
        writeGeneration += 1
        refreshingFeedURLs.removeAll()
    }

    func resetAfterDataNuke() {
        state = .idle
        subscriptions.removeAll()
        episodes.removeAll()
        progressRecords.removeAll()
        refreshLogs.removeAll()
        refreshingFeedURLs.removeAll()
        activePodcastIDs.removeAll()
        visibleEpisodeIDs.removeAll()
        inboxEpisodes.removeAll()
        podcastCacheByFeedURL.removeAll()
        latestRefreshLogByFeedURL.removeAll()
        lastErrorMessage = nil
    }

    func episode(with id: String) -> EpisodeCacheRecord? {
        let activeIDs = activePodcastIDs
        return episodes.first { $0.episodeID == id && activeIDs.contains($0.podcastID) }
    }

    func episodes(forPodcastID podcastID: String) -> [EpisodeCacheRecord] {
        guard activePodcastIDs.contains(podcastID) else {
            return []
        }

        return episodes
            .filter { $0.podcastID == podcastID }
            .sorted(by: EpisodeCacheRecord.newestFirst)
    }

    func podcastCache(for feedURL: String) -> PodcastCacheRecord? {
        podcastCacheByFeedURL[feedURL]
    }

    func isActivelySubscribed(to feedURL: String) -> Bool {
        activePodcastIDs.contains(feedURL)
    }

    func isRefreshing(feedURL: String) -> Bool {
        refreshingFeedURLs.contains(feedURL)
    }

    func latestRefreshLog(feedURL: String) -> RefreshLogRecord? {
        latestRefreshLogByFeedURL[feedURL]
    }

    func domainEpisode(for record: EpisodeCacheRecord) -> Episode {
        Episode(
            id: EpisodeID(rawValue: record.episodeID),
            podcastID: PodcastID(rawValue: record.podcastID),
            podcastTitle: record.podcastTitle,
            title: record.title,
            summary: record.summary,
            showNotesHTML: record.showNotesHTML,
            publishedAt: record.publishedAt,
            duration: record.duration,
            audioURL: record.audioURL.flatMap(URL.init(string:)),
            artworkURL: record.artworkURL.flatMap(URL.init(string:)),
            guid: record.guid
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
        progressRecords
            .filter { $0.episodeID == episodeID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func progressSummary(for episode: EpisodeCacheRecord) -> EpisodeProgressSummary {
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

    func canRestorePlayback(for episode: EpisodeCacheRecord) -> Bool {
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
        _ episode: EpisodeCacheRecord,
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
        for episode: EpisodeCacheRecord,
        modelContext: ModelContext
    ) -> Bool {
        guard activePodcastIDs.contains(episode.podcastID),
              preview.matchesArtworkURLString(episode.artworkURL)
        else {
            return false
        }

        return persistArtworkPreview(preview, to: episode, modelContext: modelContext)
    }

    @discardableResult
    func updateArtworkPreview(
        _ preview: ArtworkPreview,
        for podcast: PodcastCacheRecord,
        modelContext: ModelContext
    ) -> Bool {
        guard activePodcastIDs.contains(podcast.feedURL),
              preview.matchesArtworkURLString(podcast.artworkURL)
        else {
            return false
        }

        return persistArtworkPreview(preview, to: podcast, modelContext: modelContext)
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
        for episode: EpisodeCacheRecord,
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
        let log = RefreshLogRecord(feedURL: feedURLString)
        modelContext.insert(log)

        defer {
            refreshingFeedURLs.remove(feedURLString)
        }

        guard let feedURL = URL(string: feedURLString),
              feedURL.scheme != nil,
              feedURL.host != nil
        else {
            log.finishedAt = .now
            log.errorMessage = OpenCastCoreError.invalidFeedURL.localizedDescription
            try pruneRefreshLogs(feedURL: feedURLString, modelContext: modelContext)
            try modelContext.save()
            return
        }

        do {
            let snapshot = try await feedService.fetchFeed(at: feedURL)
            try Task.checkCancellation()
            try ensureCurrentGeneration(generation)
            try upsert(snapshot: snapshot, modelContext: modelContext, subscribe: false)
            log.finishedAt = .now
            log.errorMessage = nil
            try pruneRefreshLogs(feedURL: feedURLString, modelContext: modelContext)
            try modelContext.save()
        } catch is CancellationError {
            modelContext.delete(log)
            try? modelContext.save()
            throw CancellationError()
        } catch {
            log.finishedAt = .now
            log.errorMessage = error.localizedDescription
            try pruneRefreshLogs(feedURL: feedURLString, modelContext: modelContext)
            try modelContext.save()
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

        var refreshLogsByFeedURL: [String: RefreshLogRecord] = [:]
        for feedURLString in feedURLStrings {
            let log = RefreshLogRecord(feedURL: feedURLString)
            refreshLogsByFeedURL[feedURLString] = log
            modelContext.insert(log)
        }
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
                    try applyRefreshResult(
                        result,
                        refreshLogsByFeedURL: refreshLogsByFeedURL,
                        modelContext: modelContext
                    )
                }
            }
        } catch is CancellationError {
            refreshingFeedURLs.subtract(feedURLStrings)
            for log in refreshLogsByFeedURL.values where log.finishedAt == nil {
                modelContext.delete(log)
            }
            try? modelContext.save()
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
        refreshLogsByFeedURL: [String: RefreshLogRecord],
        modelContext: ModelContext
    ) throws {
        guard let log = refreshLogsByFeedURL[result.feedURLString] else {
            return
        }

        defer {
            refreshingFeedURLs.remove(result.feedURLString)
        }

        switch result.outcome {
        case .success(let snapshot):
            do {
                try upsert(snapshot: snapshot, modelContext: modelContext, subscribe: false)
                log.finishedAt = .now
                log.errorMessage = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.finishedAt = .now
                log.errorMessage = error.localizedDescription
            }
        case .failure(let message):
            log.finishedAt = .now
            log.errorMessage = message
        case .cancelled:
            modelContext.delete(log)
            throw CancellationError()
        }

        try pruneRefreshLogs(feedURL: result.feedURLString, modelContext: modelContext)
        try modelContext.save()
    }

    private func reloadFromStore(modelContext: ModelContext) throws {
        let fetchedSubscriptions = try modelContext.fetch(
            FetchDescriptor<SubscriptionRecord>(
                sortBy: [SortDescriptor(\.title)]
            )
        )
        subscriptions = fetchedSubscriptions.filter { !$0.isArchived }
        activePodcastIDs = Set(subscriptions.map(\.feedURL))
        let podcastCaches = try modelContext.fetch(FetchDescriptor<PodcastCacheRecord>())

        let activeIDs = activePodcastIDs
        let fetchedEpisodes = try modelContext.fetch(
            FetchDescriptor<EpisodeCacheRecord>(
                sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
            )
        )
        episodes = fetchedEpisodes.filter { activeIDs.contains($0.podcastID) }
        visibleEpisodeIDs = Set(episodes.map(\.episodeID))
        progressRecords = try modelContext.fetch(FetchDescriptor<EpisodeProgressRecord>())
        refreshLogs = try modelContext.fetch(FetchDescriptor<RefreshLogRecord>())
            .sorted(by: Self.refreshLogNewestFirst)
        rebuildDerivedLibraryData(podcastCaches: podcastCaches)
    }

    private func reloadProgressRecords(modelContext: ModelContext) throws {
        progressRecords = try modelContext.fetch(FetchDescriptor<EpisodeProgressRecord>())
    }

    @discardableResult
    private func persistArtworkPreview(
        _ preview: ArtworkPreview,
        to record: some ArtworkPreviewStoring,
        modelContext: ModelContext
    ) -> Bool {
        do {
            guard record.storeArtworkPreviewIfChanged(preview) else {
                return false
            }

            try modelContext.save()
            return true
        } catch {
            recordFailure(error)
            return false
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

    private func upsert(
        snapshot: FeedSnapshot,
        modelContext: ModelContext,
        subscribe: Bool
    ) throws {
        let canonicalFeedURL = snapshot.podcast.id.rawValue
        let now = Date.now

        var subscriptionDescriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { record in
                record.feedURL == canonicalFeedURL
            }
        )
        subscriptionDescriptor.fetchLimit = 1
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
        }

        var podcastDescriptor = FetchDescriptor<PodcastCacheRecord>(
            predicate: #Predicate { record in
                record.feedURL == canonicalFeedURL
            }
        )
        podcastDescriptor.fetchLimit = 1
        if let existingPodcast = try modelContext.fetch(podcastDescriptor).first {
            existingPodcast.title = snapshot.podcast.title
            existingPodcast.author = snapshot.podcast.author
            existingPodcast.summary = snapshot.podcast.summary
            existingPodcast.websiteURL = snapshot.podcast.websiteURL?.absoluteString
            let artworkURL = snapshot.podcast.artworkURL?.absoluteString
            existingPodcast.clearArtworkPreviewIfURLChanged(to: artworkURL)
            existingPodcast.artworkURL = artworkURL
            existingPodcast.updatedAt = now
        } else {
            modelContext.insert(
                PodcastCacheRecord(
                    feedURL: canonicalFeedURL,
                    title: snapshot.podcast.title,
                    author: snapshot.podcast.author,
                    summary: snapshot.podcast.summary,
                    websiteURL: snapshot.podcast.websiteURL?.absoluteString,
                    artworkURL: snapshot.podcast.artworkURL?.absoluteString,
                    updatedAt: now
                )
            )
        }

        let existingEpisodes = try modelContext.fetch(
            FetchDescriptor<EpisodeCacheRecord>(
                predicate: #Predicate { record in
                    record.podcastID == canonicalFeedURL
                }
            )
        )
        var existingByID: [String: EpisodeCacheRecord] = [:]
        for existingEpisode in existingEpisodes where existingByID[existingEpisode.episodeID] == nil {
            existingByID[existingEpisode.episodeID] = existingEpisode
        }

        for episode in snapshot.episodes {
            if let existingEpisode = existingByID[episode.id.rawValue] {
                existingEpisode.podcastTitle = episode.podcastTitle
                existingEpisode.title = episode.title
                existingEpisode.summary = episode.summary
                existingEpisode.showNotesHTML = episode.showNotesHTML
                existingEpisode.publishedAt = episode.publishedAt
                existingEpisode.duration = episode.duration
                existingEpisode.audioURL = episode.audioURL?.absoluteString
                let artworkURL = episode.artworkURL?.absoluteString
                existingEpisode.clearArtworkPreviewIfURLChanged(to: artworkURL)
                existingEpisode.artworkURL = artworkURL
                existingEpisode.guid = episode.guid
                existingEpisode.cachedAt = now
            } else {
                let record = EpisodeCacheRecord(
                    episodeID: episode.id.rawValue,
                    podcastID: episode.podcastID.rawValue,
                    podcastTitle: episode.podcastTitle,
                    title: episode.title,
                    summary: episode.summary,
                    showNotesHTML: episode.showNotesHTML,
                    publishedAt: episode.publishedAt,
                    duration: episode.duration,
                    audioURL: episode.audioURL?.absoluteString,
                    artworkURL: episode.artworkURL?.absoluteString,
                    guid: episode.guid,
                    cachedAt: now
                )
                modelContext.insert(record)
                existingByID[record.episodeID] = record
            }
        }

        try modelContext.save()
    }

    private func pruneRefreshLogs(feedURL: String, modelContext: ModelContext) throws {
        let logs = try modelContext.fetch(FetchDescriptor<RefreshLogRecord>())
            .filter { $0.feedURL == feedURL }
            .sorted(by: Self.refreshLogNewestFirst)

        guard logs.count > Self.refreshLogRetentionLimit else {
            return
        }

        for log in logs.dropFirst(Self.refreshLogRetentionLimit) {
            modelContext.delete(log)
        }
    }

    private func isForegroundRefreshDue(now: Date) -> Bool {
        subscriptions.contains { subscription in
            guard let lastRefreshActivity = lastRefreshActivity(for: subscription) else {
                return true
            }

            return now.timeIntervalSince(lastRefreshActivity) >= Self.foregroundRefreshInterval
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

    private static func refreshLogNewestFirst(_ lhs: RefreshLogRecord, _ rhs: RefreshLogRecord) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }

        switch (lhs.finishedAt, rhs.finishedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }

        if lhs.feedURL != rhs.feedURL {
            return lhs.feedURL < rhs.feedURL
        }

        return lhs.refreshID < rhs.refreshID
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

    private func rebuildDerivedLibraryData(podcastCaches: [PodcastCacheRecord]) {
        rebuildPodcastCacheByFeedURL(podcastCaches: podcastCaches)
        rebuildInboxEpisodes()
        rebuildLatestRefreshLogByFeedURL()
    }

    private func rebuildPodcastCacheByFeedURL(podcastCaches: [PodcastCacheRecord]) {
        podcastCacheByFeedURL = Dictionary(
            podcastCaches.map { ($0.feedURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func rebuildInboxEpisodes() {
        let activeIDs = activePodcastIDs
        inboxEpisodes = episodes
            .filter { activeIDs.contains($0.podcastID) }
            .sorted(by: EpisodeCacheRecord.newestFirst)
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

private extension EpisodeCacheRecord {
    static func newestFirst(_ lhs: EpisodeCacheRecord, _ rhs: EpisodeCacheRecord) -> Bool {
        switch (lhs.publishedAt, rhs.publishedAt) {
        case let (lhsDate?, rhsDate?):
            lhsDate > rhsDate
        case (.some, .none):
            true
        case (.none, .some):
            false
        case (.none, .none):
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
