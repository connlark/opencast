import Intents
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Siri play media handler")
struct SiriPlayMediaHandlerTests {
    @Test("An identified episode starts silently at the requested speed")
    func identifiedEpisodePlayback() async throws {
        let fixture = try await makeFixture()
        let intent = SiriPlayMediaIntentFactory.make(
            mediaItems: [
                SiriPlayMediaIntentFactory.mediaItem(
                    identifier: "newest",
                    title: "Newest Episode",
                    type: .podcastEpisode,
                    artist: "Example Show"
                )
            ],
            playbackSpeed: 2
        )

        let response = await fixture.handler.handle(intent: intent)

        #expect(response.code == .success)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "newest")
        #expect(fixture.appModel.playback.rate == 2)
        #expect(try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.playbackRatePreferenceKey,
            modelContext: fixture.modelContext
        )?.value == "2.0")
        #expect(fixture.appModel.nowPlayingPresentationRequest == 0)
    }

    @Test("A donated show uses the same primary-action episode as the phone")
    func donatedShowPlayback() async throws {
        let fixture = try await makeFixture()
        let intent = SiriPlayMediaIntentFactory.make(
            mediaContainer: SiriPlayMediaIntentFactory.mediaItem(
                identifier: Self.feedURL,
                title: "Example Show",
                type: .podcastShow
            )
        )

        let response = await fixture.handler.handle(intent: intent)

        #expect(response.code == .success)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "newest")
    }

    @Test("A generic request falls back to the newest Inbox episode")
    func genericFallback() async throws {
        let fixture = try await makeFixture()
        let response = await fixture.handler.handle(
            intent: SiriPlayMediaIntentFactory.make(resumePlayback: true)
        )

        #expect(response.code == .success)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "newest")
    }

    @Test("A generic request resumes the remembered episode before using Inbox")
    func rememberedEpisodeResume() async throws {
        let fixture = try await makeFixture()
        let playOlder = SiriPlayMediaIntentFactory.make(
            mediaItems: [
                SiriPlayMediaIntentFactory.mediaItem(
                    identifier: "older",
                    title: "Older Episode",
                    type: .podcastEpisode,
                    artist: "Example Show"
                )
            ]
        )
        let resume = SiriPlayMediaIntentFactory.make(resumePlayback: true)

        #expect(await fixture.handler.handle(intent: playOlder).code == .success)
        #expect(await fixture.handler.confirm(intent: resume).code == .ready)
        #expect(await fixture.handler.handle(intent: resume).code == .success)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "older")
    }

    @Test("Unknown media fails without starting playback")
    func unknownMediaFailure() async throws {
        let fixture = try await makeFixture()
        let intent = SiriPlayMediaIntentFactory.make(
            mediaName: "Not Subscribed",
            mediaType: .podcastShow
        )

        let response = await fixture.handler.handle(intent: intent)

        #expect(response.code == .failure)
        #expect(fixture.appModel.playback.currentEpisode == nil)
    }

    @Test("A stale identifier fails instead of falling back to a same-titled episode")
    func staleIdentifierFailure() async throws {
        let fixture = try await makeFixture()
        let intent = SiriPlayMediaIntentFactory.make(
            mediaItems: [
                SiriPlayMediaIntentFactory.mediaItem(
                    identifier: "missing-episode",
                    title: "Newest Episode",
                    type: .podcastEpisode,
                    artist: "Example Show"
                )
            ]
        )

        let response = await fixture.handler.handle(intent: intent)

        #expect(response.code == .failure)
        #expect(fixture.appModel.playback.currentEpisode == nil)
    }

    @Test("Direct resolution accepts an identified subscribed show")
    func resolveIdentifiedShow() async throws {
        let fixture = try await makeFixture()
        let intent = SiriPlayMediaIntentFactory.make(
            mediaContainer: SiriPlayMediaIntentFactory.mediaItem(
                identifier: Self.feedURL,
                title: "Example Show",
                type: .podcastShow
            )
        )

        let results = await fixture.handler.resolveMediaItems(for: intent)

        #expect(results.count == 1)
        #expect(await fixture.handler.resolution(for: intent) == .show(podcastID: Self.feedURL))
    }

    @Test("Direct resolution accepts an identified cached episode")
    func resolveIdentifiedEpisode() async throws {
        let fixture = try await makeFixture()
        let intent = SiriPlayMediaIntentFactory.make(
            mediaItems: [
                SiriPlayMediaIntentFactory.mediaItem(
                    identifier: "older",
                    title: "Older Episode",
                    type: .podcastEpisode
                )
            ]
        )

        let results = await fixture.handler.resolveMediaItems(for: intent)

        #expect(results.count == 1)
        #expect(await fixture.handler.resolution(for: intent) == .episode(episodeID: "older"))
    }

    @Test("Direct resolution finds a uniquely named episode")
    func resolveNamedEpisode() async throws {
        let fixture = try await makeFixture()
        let intent = SiriPlayMediaIntentFactory.make(
            mediaName: "Older Episode",
            mediaType: .podcastEpisode
        )

        let results = await fixture.handler.resolveMediaItems(for: intent)

        #expect(results.count == 1)
        #expect(await fixture.handler.resolution(for: intent) == .episode(episodeID: "older"))
    }

    @Test("Direct resolution rejects ambiguous and missing names")
    func resolveAmbiguityAndNoMatch() async throws {
        let fixture = try await makeFixture()
        let ambiguous = SiriPlayMediaIntentFactory.make(
            mediaName: "Shared Episode",
            mediaType: .podcastEpisode
        )
        let missing = SiriPlayMediaIntentFactory.make(
            mediaName: "Missing Episode",
            mediaType: .podcastEpisode
        )

        #expect(await fixture.handler.resolveMediaItems(for: ambiguous).count == 1)
        #expect(await fixture.handler.resolution(for: ambiguous) == .noMatch)
        #expect(await fixture.handler.resolveMediaItems(for: missing).count == 1)
        #expect(await fixture.handler.resolution(for: missing) == .noMatch)
    }

    @Test("Direct resolution rejects stale show and episode identifiers")
    func resolveStaleIdentifiers() async throws {
        let fixture = try await makeFixture()
        let staleShow = SiriPlayMediaIntentFactory.make(
            mediaContainer: SiriPlayMediaIntentFactory.mediaItem(
                identifier: "https://example.com/stale.xml",
                title: "Example Show",
                type: .podcastShow
            )
        )
        let staleEpisode = SiriPlayMediaIntentFactory.make(
            mediaItems: [
                SiriPlayMediaIntentFactory.mediaItem(
                    identifier: "stale-episode",
                    title: "Older Episode",
                    type: .podcastEpisode
                )
            ]
        )

        #expect(await fixture.handler.resolveMediaItems(for: staleShow).count == 1)
        #expect(await fixture.handler.resolution(for: staleShow) == .noMatch)
        #expect(await fixture.handler.resolveMediaItems(for: staleEpisode).count == 1)
        #expect(await fixture.handler.resolution(for: staleEpisode) == .noMatch)
    }

    @Test("Direct async confirmation reports ready and failure codes")
    func directConfirmation() async throws {
        let fixture = try await makeFixture()
        let playable = SiriPlayMediaIntentFactory.make(
            mediaName: "Older Episode",
            mediaType: .podcastEpisode
        )
        let missing = SiriPlayMediaIntentFactory.make(
            mediaName: "Missing Episode",
            mediaType: .podcastEpisode
        )

        #expect(await fixture.handler.confirm(intent: playable).code == .ready)
        #expect(await fixture.handler.confirm(intent: missing).code == .failure)
    }

    @Test("An identified playlist plays its first unplayed episode silently and tags the rest")
    func identifiedPlaylistPlaysSilentlyAndTagsTheQueue() async throws {
        let fixture = try await makeFixture()
        let playlistID = try await createPlaylist(
            "Commute",
            episodeIDs: ["older", "newest", "shared-one"],
            playedEpisodeIDs: ["older"],
            fixture: fixture
        )
        let intent = SiriPlayMediaIntentFactory.make(
            mediaContainer: SiriPlayMediaIntentFactory.mediaItem(
                identifier: playlistID,
                title: "Commute",
                type: .podcastPlaylist
            )
        )

        let response = await fixture.handler.handle(intent: intent)

        #expect(response.code == .success)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "newest")
        #expect(fixture.appModel.upNextQueue.items.map(\.episodeID) == ["shared-one"])
        #expect(fixture.appModel.upNextQueue.items.map(\.sourcePlaylistID) == [playlistID])
        #expect(fixture.appModel.currentPlaylistSourceID == playlistID)
        // The phone sheet request is posted from a Task after a yield.
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(fixture.appModel.nowPlayingPresentationRequest == 0)
    }

    @Test("Confirming a playlist with nothing unplayed reports no unplayed content")
    func confirmOnAllPlayedPlaylistReturnsNoUnplayedContent() async throws {
        let fixture = try await makeFixture()
        let playlistID = try await createPlaylist(
            "Done",
            episodeIDs: ["older"],
            playedEpisodeIDs: ["older"],
            fixture: fixture
        )
        let intent = SiriPlayMediaIntentFactory.make(
            mediaContainer: SiriPlayMediaIntentFactory.mediaItem(
                identifier: playlistID,
                title: "Done",
                type: .podcastPlaylist
            )
        )

        #expect(await fixture.handler.resolution(for: intent) == .playlist(playlistID: playlistID))
        #expect(await fixture.handler.confirm(intent: intent).code == .failureNoUnplayedContent)
        #expect(await fixture.handler.handle(intent: intent).code == .failureNoUnplayedContent)
        #expect(fixture.appModel.playback.currentEpisode == nil)
    }

    @Test("A playlist-typed donation carrying a feed URL still plays the show")
    func feedURLPodcastPlaylistIdentifierStillPlaysTheShow() async throws {
        let fixture = try await makeFixture()
        let intent = SiriPlayMediaIntentFactory.make(
            mediaContainer: SiriPlayMediaIntentFactory.mediaItem(
                identifier: Self.feedURL,
                title: "Example Show",
                type: .podcastPlaylist
            )
        )

        // Resolution reads the library, which only hydration loads.
        let results = await fixture.handler.resolveMediaItems(for: intent)

        #expect(results.count == 1)
        #expect(await fixture.handler.resolution(for: intent) == .show(podcastID: Self.feedURL))
        #expect(await fixture.handler.handle(intent: intent).code == .success)
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == "newest")
        #expect(fixture.appModel.currentPlaylistSourceID == nil)
    }

    @Test("A spoken playlist name resolves to a playlist media item")
    func spokenPlaylistNameResolvesToAPlaylistMediaItem() async throws {
        let fixture = try await makeFixture()
        let playlistID = try await createPlaylist("Commute", episodeIDs: ["newest"], fixture: fixture)
        let intent = SiriPlayMediaIntentFactory.make(mediaName: "Commute", mediaType: .unknown)

        let results = await fixture.handler.resolveMediaItems(for: intent)

        #expect(await fixture.handler.resolution(for: intent) == .playlist(playlistID: playlistID))
        #expect(results.count == 1)
        let result = try #require(results.first)
        // Resolution results expose no public accessor for their value; the
        // responds(to:) guard turns a renamed private key into a failure
        // instead of an exception that takes the test host down.
        try #require(result.responds(to: NSSelectorFromString("resolvedValue")))
        let item = try #require(result.value(forKey: "resolvedValue") as? INMediaItem)
        #expect(item.identifier == playlistID)
        #expect(item.title == "Commute")
        #expect(item.type == .podcastPlaylist)
    }

    private static let feedURL = "https://example.com/siri-handler.xml"

    /// Hydrates first, as the handler would, so the new rows are not replaced
    /// by a later load and the episodes resolve.
    private func createPlaylist(
        _ name: String,
        episodeIDs: [String],
        playedEpisodeIDs: [String] = [],
        fixture: (handler: SiriPlayMediaHandler, appModel: OpenCastAppModel, modelContext: ModelContext)
    ) async throws -> String {
        let appModel = fixture.appModel
        let context = fixture.modelContext
        await appModel.ensurePlaybackSurfaceHydrated(modelContext: context)
        let playlist = try #require(appModel.playlists.create(name: name, kind: .manual, modelContext: context))
        let episodes = try episodeIDs.map { try #require(appModel.episodeSnapshot(for: $0)) }
        #expect(appModel.playlists.add(episodes, to: playlist.playlistID, modelContext: context) == episodes.count)
        for episodeID in playedEpisodeIDs {
            let episode = try #require(appModel.episodeSnapshot(for: episodeID))
            #expect(appModel.markEpisodePlayed(episode, modelContext: context))
        }
        return playlist.playlistID
    }

    private func makeFixture() async throws -> (
        handler: SiriPlayMediaHandler,
        appModel: OpenCastAppModel,
        modelContext: ModelContext
    ) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: Self.feedURL, title: "Example Show"))
        try context.save()

        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let podcastID = PodcastID(rawValue: Self.feedURL)
        let snapshot = FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: try #require(URL(string: Self.feedURL)),
                title: "Example Show"
            ),
            episodes: [
                episode(
                    id: "newest",
                    podcastID: podcastID,
                    title: "Newest Episode",
                    publishedAt: Date(timeIntervalSince1970: 400)
                ),
                episode(
                    id: "older",
                    podcastID: podcastID,
                    title: "Older Episode",
                    publishedAt: Date(timeIntervalSince1970: 300)
                ),
                episode(
                    id: "shared-one",
                    podcastID: podcastID,
                    title: "Shared Episode",
                    publishedAt: Date(timeIntervalSince1970: 200)
                ),
                episode(
                    id: "shared-two",
                    podcastID: podcastID,
                    title: "Shared Episode",
                    publishedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )
        try await cache.upsertCache(from: snapshot, refreshedAt: .now)
        let appModel = OpenCastAppModel(
            localLibraryCacheStore: cache,
            allowsAutomaticFeedRefresh: false
        )
        return (
            SiriPlayMediaHandler(appModel: appModel, modelContext: context),
            appModel,
            context
        )
    }

    private func episode(
        id: String,
        podcastID: PodcastID,
        title: String,
        publishedAt: Date
    ) -> Episode {
        Episode(
            id: EpisodeID(rawValue: id),
            podcastID: podcastID,
            podcastTitle: "Example Show",
            title: title,
            publishedAt: publishedAt,
            duration: 120,
            audioURL: URL(string: "https://example.com/\(id).mp3")
        )
    }
}
