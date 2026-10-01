import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("System actions")
struct OpenCastSystemActionTests {
    @Test func coldLaunchHydratesOnceAndPreservesQueueOrder() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        try await fixture.model.systemActions.perform(.enqueue("episode-1"), modelContext: fixture.context)
        try await fixture.model.systemActions.perform(.enqueue("episode-2"), modelContext: fixture.context)
        try await fixture.model.systemActions.perform(.enqueue("episode-1"), modelContext: fixture.context)
        #expect(fixture.model.upNextQueue.items.map(\.episodeID) == ["episode-1", "episode-2"])
        #expect(fixture.model.playbackSurfaceRestorationCount == 1)
        #expect(fixture.model.playback.currentEpisode == nil)
    }

    @Test func deletedIDDoesNotSelectAnotherAmbiguousTitle() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        await #expect(throws: OpenCastSystemActionError.self) {
            try await fixture.model.systemActions.perform(.playEpisode("deleted"), modelContext: fixture.context)
        }
        #expect(fixture.model.playback.currentEpisode == nil)
    }

    @Test func latestUnplayedUsesPublicationOrder() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        try await fixture.model.systemActions.perform(.playLatest(OpenCastSystemActionFixture.feed), modelContext: fixture.context)
        defer { fixture.model.playback.pause() }
        #expect(fixture.model.playback.currentEpisode?.id.rawValue == "episode-2")
        #expect(fixture.model.playback.currentItemSourceIdentity?.assetURL.absoluteString == "https://example.com/2.mp3")
        fixture.model.playback.seek(to: 40)
        fixture.model.playback.pause()
        try await fixture.model.systemActions.perform(.resume, modelContext: fixture.context)
        #expect(fixture.model.playback.position == 40)
    }

    @Test func missingAudioReturnsStructuredFailure() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        await #expect(throws: OpenCastSystemActionError.self) {
            try await fixture.model.systemActions.perform(.playEpisode("episode-0"), modelContext: fixture.context)
        }
    }

    @Test func cancellationDoesNotStartPlayback() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        let task = Task {
            try await fixture.model.systemActions.perform(.playEpisode("episode-1"), modelContext: fixture.context)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.model.playback.currentEpisode == nil)
    }

    @Test func catalogLimitsPreserveAmbiguityAndStableIDs() async throws {
        let fixture = try await OpenCastSystemActionFixture.make(episodeCount: 105)
        await fixture.model.ensurePlaybackSurfaceHydrated(modelContext: fixture.context)
        let catalog = OpenCastEntityCatalog(library: fixture.model.library)
        #expect(catalog.shows.map(\.id) == [OpenCastSystemActionFixture.feed])
        #expect(catalog.episodes.count == 100)
        #expect(catalog.episodes.first?.id == "episode-104")
        #expect(catalog.episodes.allSatisfy { $0.title == "Shared Title" })
        #expect(OpenCastIndexRevision(catalog: catalog) == OpenCastIndexRevision(catalog: catalog))
    }

    @Test func searchOpensWithBoundedInput() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        try await fixture.model.systemActions.perform(.search(String(repeating: "a", count: 300)), modelContext: fixture.context)
        #expect(fixture.model.systemSearchRequest?.query.count == 256)
        #expect(fixture.model.playback.currentEpisode == nil)
    }

    @Test func unsubscribeRemovesCatalogAndSavedActionAvailability() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        await fixture.model.ensurePlaybackSurfaceHydrated(modelContext: fixture.context)
        await fixture.model.library.unsubscribe(feedURL: OpenCastSystemActionFixture.feed, modelContext: fixture.context)
        let catalog = OpenCastEntityCatalog(library: fixture.model.library)
        #expect(catalog.shows.isEmpty)
        #expect(catalog.episodes.isEmpty)
        await #expect(throws: OpenCastSystemActionError.self) {
            try await fixture.model.systemActions.perform(.enqueue("episode-1"), modelContext: fixture.context)
        }
    }

    @Test func queueSaveFailureIsAnIntentFailure() async throws {
        let queue = UpNextQueueStore { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let fixture = try await OpenCastSystemActionFixture.make(queue: queue)
        await #expect(throws: OpenCastSystemActionError.self) {
            try await fixture.model.systemActions.perform(.enqueue("episode-1"), modelContext: fixture.context)
        }
        #expect(fixture.model.upNextQueue.items.isEmpty)
    }

    @Test func queryRejectsUnboundedIdentifierRequests() async {
        await #expect(throws: OpenCastSystemActionError.self) {
            _ = try await OpenCastEpisodeQuery().entities(for: Array(repeating: "id", count: 101))
        }
    }

    @Test func downloadedPlaybackResumesPersistedProgress() async throws {
        let directory = URL.temporaryDirectory.appending(path: "intent-download-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = EpisodeDownloadFileStore(baseDirectory: directory)
        let fixture = try await OpenCastSystemActionFixture.make(downloads: DownloadStore(fileStore: fileStore))
        let source = URL(string: "https://example.com/1.mp3")!
        let relativePath = fileStore.relativePath(episodeID: "episode-1", sourceAudioURL: source)
        try fileStore.prepareDownloadsDirectory()
        let file = fileStore.fileURL(relativePath: relativePath)
        _ = try PCM16WAVWriter.write(to: file, durationSeconds: 120) { _ in 0 }
        fixture.context.insert(EpisodeDownloadRecord(episodeID: "episode-1", podcastID: OpenCastSystemActionFixture.feed, sourceAudioURL: source.absoluteString, localRelativePath: relativePath, state: .completed))
        fixture.context.insert(EpisodeProgressRecord(episodeID: "episode-1", podcastID: OpenCastSystemActionFixture.feed, position: 40, duration: 120, updatedAt: .now))
        try fixture.context.save()
        try await fixture.model.systemActions.perform(.playEpisode("episode-1"), modelContext: fixture.context)
        defer { fixture.model.playback.unload() }
        #expect(fixture.model.playback.currentItemSourceIdentity?.assetURL == file)
        // Fresh progress resumes through the tier-1 smart rewind (3 s).
        #expect(fixture.model.playback.position == 37)
    }

    @Test func playPlaylistReplacesQueueAndStartsSilently() async throws {
        let fixture = try await OpenCastSystemActionFixture.make(episodeCount: 4)
        let playlists = try await fixture.seedPlaylists()
        try await fixture.model.systemActions.perform(.enqueue("episode-3"), modelContext: fixture.context)
        try await fixture.model.systemActions.perform(.playPlaylist(playlists.commuteID), modelContext: fixture.context)
        defer { fixture.model.playback.pause() }
        #expect(fixture.model.playback.currentEpisode?.id.rawValue == "episode-1")
        #expect(fixture.model.upNextQueue.items.map(\.episodeID) == ["episode-2"])
        #expect(fixture.model.upNextQueue.items.map(\.sourcePlaylistID) == [playlists.commuteID])
        #expect(fixture.model.currentPlaylistSourceID == playlists.commuteID)
        // The phone sheet request is posted from a Task after a yield.
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(fixture.model.nowPlayingPresentationRequest == 0)
    }

    @Test func playPlaylistMissingThrowsUnavailable() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        _ = try await fixture.seedPlaylists()
        await #expect(throws: OpenCastSystemActionError.unavailable) {
            try await fixture.model.systemActions.perform(.playPlaylist("missing-playlist"), modelContext: fixture.context)
        }
        #expect(fixture.model.playback.currentEpisode == nil)
    }

    @Test func playPlaylistEmptyOrAllPlayedThrowsNoUnplayed() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        let playlists = try await fixture.seedPlaylists()
        await #expect(throws: OpenCastSystemActionError.playlistHasNoUnplayedEpisodes) {
            try await fixture.model.systemActions.perform(.playPlaylist(playlists.emptyID), modelContext: fixture.context)
        }
        await #expect(throws: OpenCastSystemActionError.playlistHasNoUnplayedEpisodes) {
            try await fixture.model.systemActions.perform(.playPlaylist(playlists.allPlayedID), modelContext: fixture.context)
        }
        #expect(fixture.model.playback.currentEpisode == nil)
        #expect(fixture.model.upNextQueue.items.isEmpty)
    }

    @Test func addToPlaylistSaveFailureIsAnIntentFailure() async throws {
        let playlists = PlaylistStore(saveModelContext: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let fixture = try await OpenCastSystemActionFixture.make(playlists: playlists)
        let seeded = try await fixture.seedPlaylists()
        await #expect(throws: OpenCastSystemActionError.playlistFailed) {
            try await fixture.model.systemActions.perform(
                .addToPlaylist(episodeID: "episode-1", playlistID: seeded.emptyID),
                modelContext: fixture.context
            )
        }
        #expect(fixture.model.playlists.itemsByPlaylistID[seeded.emptyID]?.isEmpty != false)
    }

    @Test func addToPlaylistIsIdempotent() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        let playlists = try await fixture.seedPlaylists()
        for _ in 0..<2 {
            try await fixture.model.systemActions.perform(
                .addToPlaylist(episodeID: "episode-1", playlistID: playlists.emptyID),
                modelContext: fixture.context
            )
        }
        #expect(fixture.model.playlists.itemsByPlaylistID[playlists.emptyID]?.count == 1)
        #expect(fixture.model.playlists.itemsByPlaylistID[playlists.emptyID]?.map(\.episodeID) == ["episode-1"])
        #expect(fixture.model.playback.currentEpisode == nil)
    }

    @Test func addToSmartPlaylistThrows() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        let playlists = try await fixture.seedPlaylists()
        await #expect(throws: OpenCastSystemActionError.smartPlaylistRejectsEpisodes) {
            try await fixture.model.systemActions.perform(
                .addToPlaylist(episodeID: "episode-1", playlistID: playlists.smartID),
                modelContext: fixture.context
            )
        }
        #expect(fixture.model.playlists.itemsByPlaylistID[playlists.smartID, default: []].isEmpty)
    }

    @Test func addMissingEpisodeOrPlaylistThrowsUnavailable() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        let playlists = try await fixture.seedPlaylists()
        await #expect(throws: OpenCastSystemActionError.unavailable) {
            try await fixture.model.systemActions.perform(
                .addToPlaylist(episodeID: "deleted", playlistID: playlists.emptyID),
                modelContext: fixture.context
            )
        }
        await #expect(throws: OpenCastSystemActionError.unavailable) {
            try await fixture.model.systemActions.perform(
                .addToPlaylist(episodeID: "episode-1", playlistID: "missing-playlist"),
                modelContext: fixture.context
            )
        }
        #expect(fixture.model.playlists.itemsByPlaylistID[playlists.emptyID, default: []].isEmpty)
    }

    @Test func playlistQueryRejectsOversizedIdentifierBatch() async {
        await #expect(throws: OpenCastSystemActionError.queryTooLarge) {
            _ = try await OpenCastPlaylistQuery().entities(for: (0..<101).map(String.init))
        }
    }

    @Test func playlistEntitiesSortNewestUpdatedFirstWithInflectedCounts() async throws {
        let fixture = try await OpenCastSystemActionFixture.make()
        let playlists = try await fixture.seedPlaylists()
        await fixture.model.ensurePlaybackSurfaceHydrated(modelContext: fixture.context)
        let model = fixture.model
        // The store follows the collection's sort preference; the entities must not.
        model.playlists.sortOrder = .name
        #expect(model.playlists.playlists.map(\.playlistID).first == playlists.allPlayedID)

        let entities = OpenCastPlaylistEntity.entities(for: model.playlists.playlists) { model.playlistEpisodeCount(for: $0) }

        #expect(entities.map(\.id) == [playlists.commuteID, playlists.allPlayedID, playlists.emptyID, playlists.smartID])
        #expect(entities.prefix(3).map(\.episodeCountText) == ["2 episodes", "1 episode", "No episodes"])
        #expect(entities.prefix(3).map(\.episodeCount) == [2, 1, 0])
        #expect(entities.map(\.isSmart) == [false, false, false, true])
        #expect(entities.first?.name == "Commute")
    }

    @Test func playPlaylistQueueFailureAfterStartIsAQueueError() async throws {
        let queue = UpNextQueueStore { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let fixture = try await OpenCastSystemActionFixture.make(queue: queue)
        let playlists = try await fixture.seedPlaylists()
        await #expect(throws: OpenCastSystemActionError.queueFailed) {
            try await fixture.model.systemActions.perform(.playPlaylist(playlists.commuteID), modelContext: fixture.context)
        }
        defer { fixture.model.playback.pause() }
        #expect(fixture.model.playback.currentEpisode?.id.rawValue == "episode-1")
        #expect(fixture.model.upNextQueue.items.isEmpty)
    }
}
