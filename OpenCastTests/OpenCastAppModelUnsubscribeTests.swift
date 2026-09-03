import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("App model unsubscribe integrity")
struct OpenCastAppModelUnsubscribeTests {
    @Test("A failed subscription delete leaves sidecars and downloads intact")
    func failedSubscriptionDeleteLeavesSidecarsIntact() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/unsubscribe-fail.xml"
        let episodeID = "unsubscribe-fail-episode"
        let downloadsDirectory = FileManager.default.temporaryDirectory
            .appending(path: "unsubscribe-fail-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileStore = EpisodeDownloadFileStore(baseDirectory: downloadsDirectory)
        let downloadStore = DownloadStore(fileStore: fileStore)
        let appModel = OpenCastAppModel(
            library: LibraryStore(
                feedService: UnusedFeedService(),
                localCache: FailingDeleteCacheStore(wrapping: SQLiteLocalLibraryCacheStore.inMemory())
            ),
            downloads: downloadStore,
            allowsAutomaticFeedRefresh: false
        )
        try seedSubscribedFeed(feedURL: feedURL, episodeID: episodeID, in: context)
        try seedSidecarPreferences(feedURL: feedURL, episodeID: episodeID, in: context)
        let downloadRelativePath = try seedCompletedDownload(
            feedURL: feedURL,
            episodeID: episodeID,
            fileStore: fileStore,
            in: context
        )
        await appModel.library.load(modelContext: context)
        await downloadStore.load(modelContext: context)
        #expect(appModel.library.isActivelySubscribed(to: feedURL))

        let outcome = await appModel.unsubscribe(feedURL: feedURL, modelContext: context)

        #expect(appModel.library.isActivelySubscribed(to: feedURL))
        guard case .failed = outcome else {
            Issue.record("Expected an authoritative unsubscribe failure.")
            return
        }
        #expect(appModel.lastUnsubscribeErrorMessage != nil)
        #expect(appModel.lastPlaybackError == nil)
        // The success-gated sidecar block never ran.
        let preferenceKeys = try context.fetch(FetchDescriptor<LocalPreferenceRecord>()).map(\.key)
        #expect(preferenceKeys.contains("playback.voiceBoost.episode.\(episodeID)"))
        #expect(preferenceKeys.contains("podcastDetail.sortOrder.\(feedURL)"))
        // A still-subscribed feed keeps its audio: files cannot be rolled
        // back, and a dynamic-enclosure re-download may not be
        // byte-identical.
        #expect(fileStore.fileExists(relativePath: downloadRelativePath))
        #expect(downloadStore.record(for: episodeID) != nil)
        #expect(try context.fetch(FetchDescriptor<EpisodeDownloadRecord>()).count == 1)
    }

    @Test("A successful unsubscribe sweeps voice-boost and episode-list preferences")
    func successfulUnsubscribeSweepsSidecarPreferences() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/unsubscribe-sweep.xml"
        let keptFeedURL = "https://example.com/unsubscribe-kept.xml"
        let episodeID = "unsubscribe-sweep-episode"
        let keptEpisodeID = "unsubscribe-kept-episode"
        let appModel = makeAppModel(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        try seedSubscribedFeed(feedURL: feedURL, episodeID: episodeID, in: context)
        try seedSubscribedFeed(feedURL: keptFeedURL, episodeID: keptEpisodeID, in: context)
        try seedSidecarPreferences(feedURL: feedURL, episodeID: episodeID, in: context)
        try seedSidecarPreferences(feedURL: keptFeedURL, episodeID: keptEpisodeID, in: context)
        await appModel.library.load(modelContext: context)

        let outcome = await appModel.unsubscribe(feedURL: feedURL, modelContext: context)

        #expect(!appModel.library.isActivelySubscribed(to: feedURL))
        #expect(outcome == .removed(warning: nil))
        #expect(appModel.lastUnsubscribeErrorMessage == nil)
        #expect(appModel.lastPlaybackError == nil)
        let preferenceKeys = try context.fetch(FetchDescriptor<LocalPreferenceRecord>()).map(\.key)
        #expect(!preferenceKeys.contains("playback.voiceBoost.episode.\(episodeID)"))
        #expect(preferenceKeys.contains("playback.voiceBoost.episode.\(keptEpisodeID)"))
        #expect(!preferenceKeys.contains("podcastDetail.sortOrder.\(feedURL)"))
        #expect(preferenceKeys.contains("podcastDetail.sortOrder.\(keptFeedURL)"))
    }

    @Test("A cleanup warning keeps the podcast removed and remains visible")
    func successfulUnsubscribeSurfacesSidecarWarning() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/unsubscribe-warning.xml"
        let appModel = OpenCastAppModel(
            library: LibraryStore(
                feedService: UnusedFeedService(),
                localCache: SQLiteLocalLibraryCacheStore.inMemory()
            ),
            allowsAutomaticFeedRefresh: false,
            unsubscribeSidecarCleanupOverride: { _, _, _ in
                throw UnsubscribeSidecarFailure()
            }
        )
        try seedSubscribedFeed(feedURL: feedURL, episodeID: "warning-episode", in: context)
        await appModel.library.load(modelContext: context)

        let outcome = await appModel.unsubscribe(feedURL: feedURL, modelContext: context)

        #expect(!appModel.library.isActivelySubscribed(to: feedURL))
        guard case .removed(let warning?) = outcome else {
            Issue.record("Expected a successful removal with a cleanup warning.")
            return
        }
        #expect(warning.contains("Simulated sidecar cleanup failure"))
        #expect(appModel.lastUnsubscribeErrorMessage == warning)
    }

    @Test("Podcast detail feedback follows the authoritative unsubscribe outcome")
    func presentationDecisionMatchesOutcome() {
        let failure = PodcastUnsubscribePresentationDecision.make(
            outcome: .failed(message: "Delete failed")
        )
        #expect(!failure.emitsSuccessFeedback)
        #expect(!failure.dismissesImmediately)
        #expect(failure.alertMessage == "Delete failed")

        let success = PodcastUnsubscribePresentationDecision.make(
            outcome: .removed(warning: nil)
        )
        #expect(success.emitsSuccessFeedback)
        #expect(success.dismissesImmediately)

        let warning = PodcastUnsubscribePresentationDecision.make(
            outcome: .removed(warning: "Cleanup failed")
        )
        #expect(warning.emitsSuccessFeedback)
        #expect(!warning.dismissesImmediately)
        #expect(warning.dismissesAfterAlert)
        #expect(warning.alertMessage == "Cleanup failed")
    }

    private func makeAppModel(localCache: any LocalLibraryCacheStore) -> OpenCastAppModel {
        OpenCastAppModel(
            library: LibraryStore(
                feedService: UnusedFeedService(),
                localCache: localCache
            ),
            allowsAutomaticFeedRefresh: false
        )
    }

    private func seedSubscribedFeed(
        feedURL: String,
        episodeID: String,
        in context: ModelContext
    ) throws {
        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Show \(episodeID)"))
        context.insert(
            PodcastCacheRecord(
                feedURL: feedURL,
                title: "Show \(episodeID)",
                updatedAt: .now
            )
        )
        context.insert(
            EpisodeCacheRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                podcastTitle: "Show \(episodeID)",
                title: "Episode \(episodeID)",
                publishedAt: .now,
                duration: 120,
                audioURL: "https://example.com/\(episodeID).mp3"
            )
        )
        try context.save()
    }

    private func seedCompletedDownload(
        feedURL: String,
        episodeID: String,
        fileStore: EpisodeDownloadFileStore,
        in context: ModelContext
    ) throws -> String {
        let relativePath = fileStore.relativePath(
            episodeID: episodeID,
            sourceAudioURL: URL(string: "https://example.com/\(episodeID).mp3")!
        )
        try fileStore.prepareDownloadsDirectory()
        try Data("audio".utf8).write(
            to: fileStore.fileURL(relativePath: relativePath),
            options: .atomic
        )
        context.insert(
            EpisodeDownloadRecord(
                episodeID: episodeID,
                podcastID: feedURL,
                sourceAudioURL: "https://example.com/\(episodeID).mp3",
                localRelativePath: relativePath,
                state: .completed,
                bytesReceived: 5,
                bytesExpected: 5
            )
        )
        try context.save()
        return relativePath
    }

    private func seedSidecarPreferences(
        feedURL: String,
        episodeID: String,
        in context: ModelContext
    ) throws {
        context.insert(
            LocalPreferenceRecord(
                key: "playback.voiceBoost.episode.\(episodeID)",
                value: "false"
            )
        )
        context.insert(
            LocalPreferenceRecord(
                key: "podcastDetail.sortOrder.\(feedURL)",
                value: PodcastEpisodeSortOrder.oldestFirst.rawValue
            )
        )
        try context.save()
    }
}

private struct UnsubscribeSidecarFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated sidecar cleanup failure"
    }
}

private struct UnusedFeedService: FeedService {
    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        throw CancellationError()
    }
}

private actor FailingDeleteCacheStore: LocalLibraryCacheStore {
    private let wrapped: any LocalLibraryCacheStore

    init(wrapping wrapped: any LocalLibraryCacheStore) {
        self.wrapped = wrapped
    }

    func loadLibrary(activePodcastIDs: Set<String>) async throws -> LocalLibraryCacheSnapshot {
        try await wrapped.loadLibrary(activePodcastIDs: activePodcastIDs)
    }

    func allRefreshLogs() async throws -> [RefreshLogSnapshot] {
        try await wrapped.allRefreshLogs()
    }

    func episodeDetail(episodeID: String) async throws -> EpisodeDetailSnapshot? {
        try await wrapped.episodeDetail(episodeID: episodeID)
    }

    func showNotesHTMLByEpisodeID(activePodcastIDs: Set<String>) async throws -> [String: String] {
        try await wrapped.showNotesHTMLByEpisodeID(activePodcastIDs: activePodcastIDs)
    }

    func upsertCache(from snapshot: FeedSnapshot, refreshedAt: Date) async throws {
        try await wrapped.upsertCache(from: snapshot, refreshedAt: refreshedAt)
    }

    func updateEpisodeArtworkPreview(_ preview: ArtworkPreview, episodeID: String, artworkURL: String?) async throws {
        try await wrapped.updateEpisodeArtworkPreview(preview, episodeID: episodeID, artworkURL: artworkURL)
    }

    func updatePodcastArtworkPreview(_ preview: ArtworkPreview, feedURL: String, artworkURL: String?) async throws {
        try await wrapped.updatePodcastArtworkPreview(preview, feedURL: feedURL, artworkURL: artworkURL)
    }

    func insertRefreshLog(_ log: RefreshLogSnapshot, prunedTo retentionLimit: Int) async throws {
        try await wrapped.insertRefreshLog(log, prunedTo: retentionLimit)
    }

    func feedValidators(forPodcastID podcastID: String) async throws -> FeedValidators? {
        try await wrapped.feedValidators(forPodcastID: podcastID)
    }

    func updateFeedValidators(_ validators: FeedValidators, forPodcastID podcastID: String) async throws {
        try await wrapped.updateFeedValidators(validators, forPodcastID: podcastID)
    }

    func cachedEpisodes(forPodcastID podcastID: String) async throws -> [EpisodeListItemSnapshot] {
        try await wrapped.cachedEpisodes(forPodcastID: podcastID)
    }

    func deleteEpisodes(episodeIDs: [String]) async throws {
        try await wrapped.deleteEpisodes(episodeIDs: episodeIDs)
    }

    func deleteCache(forPodcastID podcastID: String) async throws {
        throw LocalLibraryCacheStoreError(
            operation: "feed cache delete",
            message: "Simulated cache delete failure"
        )
    }

    func deleteAllLocalCache() async throws {
        try await wrapped.deleteAllLocalCache()
    }

    func replaceNotificationFeedHealth(_ records: [NotificationFeedHealthRecord]) async throws {
        try await wrapped.replaceNotificationFeedHealth(records)
    }

    func notificationFeedHealthByFeedURL() async throws -> [String: NotificationFeedHealth] {
        try await wrapped.notificationFeedHealthByFeedURL()
    }

    func hasCompletedLegacyImport() async throws -> Bool {
        try await wrapped.hasCompletedLegacyImport()
    }

    func importLegacyCache(
        podcasts: [PodcastCacheSnapshot],
        episodes: [EpisodeDetailSnapshot],
        refreshLogs: [RefreshLogSnapshot]
    ) async throws {
        try await wrapped.importLegacyCache(
            podcasts: podcasts,
            episodes: episodes,
            refreshLogs: refreshLogs
        )
    }
}
