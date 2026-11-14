import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode publisher chapters section model")
struct EpisodePublisherChaptersSectionModelTests {
    private static let chapteredFeedURL = "https://example.com/section-chaptered.xml"
    private static let episodeID = "section-chaptered"
    private static let documentURL = "https://example.com/chapters/section-chaptered.json"
    private static let document = Data(
        #"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Opening"},{"startTime":95,"title":"Interview"}]}"#.utf8
    )

    @Test("A declared document loads its chapters for that episode only")
    func declaredDocumentLoadsChapters() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Self.document)])
        let fixture = try await OpenCastSystemActionFixture.make(httpClient: client)
        let episode = try await Self.cacheEpisode(declaringDocument: true, in: fixture.model)
        let section = EpisodePublisherChaptersSectionModel()
        let key = section.loadKey(episode: episode)
        #expect(section.suppressesGeneration(for: Self.episodeID) == nil)
        #expect(!section.isFinished(forKey: key))

        await section.load(appModel: fixture.model, episode: episode, key: key)

        #expect(section.chapters(for: Self.episodeID) == [
            EpisodeChapter(id: 0, title: "Opening", startTime: 0),
            EpisodeChapter(id: 1, title: "Interview", startTime: 95),
        ])
        #expect(section.suppressesGeneration(for: Self.episodeID) == true)
        #expect(section.isFinished(forKey: key))
        #expect(section.chapters(for: "episode-1").isEmpty)
        #expect(section.suppressesGeneration(for: "episode-1") == nil)
        #expect(!section.isFinished(forKey: Self.otherEpisodeKey(of: section, cachedAt: episode.cachedAt)))
        #expect(client.requests.map(\.url?.absoluteString) == [Self.documentURL])
    }

    @Test("An episode that declares no document loads empty with no request")
    func undeclaredDocumentLoadsEmpty() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Self.document)])
        let fixture = try await OpenCastSystemActionFixture.make(httpClient: client)
        let episode = try await Self.cacheEpisode(declaringDocument: false, in: fixture.model)
        let section = EpisodePublisherChaptersSectionModel()
        let key = section.loadKey(episode: episode)

        await section.load(appModel: fixture.model, episode: episode, key: key)

        #expect(section.chapters(for: Self.episodeID).isEmpty)
        #expect(section.suppressesGeneration(for: Self.episodeID) == false)
        #expect(section.isFinished(forKey: key))
        #expect(client.requestCount == 0)
    }

    @Test("A declared document with nothing usable loads empty and allows generation")
    func emptyDocumentAllowsGeneration() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Data(#"{"version":"1.2.0","chapters":[]}"#.utf8))])
        let fixture = try await OpenCastSystemActionFixture.make(httpClient: client)
        let episode = try await Self.cacheEpisode(declaringDocument: true, in: fixture.model)
        let section = EpisodePublisherChaptersSectionModel()
        let key = section.loadKey(episode: episode)

        await section.load(appModel: fixture.model, episode: episode, key: key)

        #expect(section.chapters(for: Self.episodeID).isEmpty)
        #expect(section.suppressesGeneration(for: Self.episodeID) == false)
        #expect(section.isFinished(forKey: key))
        #expect(client.requestCount == 1)
    }

    @Test("A declared document that cannot be read loads empty and still suppresses generation")
    func unreadableDocumentSuppressesGeneration() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Data(), statusCode: 404)])
        let fixture = try await OpenCastSystemActionFixture.make(httpClient: client)
        let episode = try await Self.cacheEpisode(declaringDocument: true, in: fixture.model)
        let section = EpisodePublisherChaptersSectionModel()
        let key = section.loadKey(episode: episode)

        await section.load(appModel: fixture.model, episode: episode, key: key)

        #expect(section.chapters(for: Self.episodeID).isEmpty)
        #expect(section.suppressesGeneration(for: Self.episodeID) == true)
        #expect(section.isFinished(forKey: key))
    }

    @Test("While a declared document resolves, generation stays suppressed with no chapters")
    func declaredDocumentSuppressesWhileResolving() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Self.document)])
        await client.hold()
        let fixture = try await OpenCastSystemActionFixture.make(httpClient: client)
        let appModel = fixture.model
        let episode = try await Self.cacheEpisode(declaringDocument: true, in: appModel)
        let section = EpisodePublisherChaptersSectionModel()
        let key = section.loadKey(episode: episode)

        let load = Task { await section.load(appModel: appModel, episode: episode, key: key) }
        #expect(await waitUntil { client.requestCount == 1 })

        #expect(section.suppressesGeneration(for: Self.episodeID) == true)
        #expect(section.chapters(for: Self.episodeID).isEmpty)
        #expect(!section.isFinished(forKey: key))

        await client.release()
        await load.value

        #expect(section.suppressesGeneration(for: Self.episodeID) == true)
        #expect(section.isFinished(forKey: key))
        #expect(section.chapters(for: Self.episodeID) == [
            EpisodeChapter(id: 0, title: "Opening", startTime: 0),
            EpisodeChapter(id: 1, title: "Interview", startTime: 95),
        ])
    }

    @Test("A load cancelled mid-fetch keeps only the suppressing state, and the fetch it started still lands")
    func cancelledLoadKeepsSuppressingState() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Self.document)])
        await client.hold()
        let fixture = try await OpenCastSystemActionFixture.make(httpClient: client)
        let appModel = fixture.model
        let episode = try await Self.cacheEpisode(declaringDocument: true, in: appModel)
        let section = EpisodePublisherChaptersSectionModel()
        let key = section.loadKey(episode: episode)

        let load = Task { await section.load(appModel: appModel, episode: episode, key: key) }
        #expect(await waitUntil { client.requestCount == 1 })
        load.cancel()
        await client.release()
        await load.value
        await appModel.publisherChapters.waitForFetch(episodeID: Self.episodeID)

        #expect(section.chapters(for: Self.episodeID).isEmpty)
        #expect(section.suppressesGeneration(for: Self.episodeID) == true)
        #expect(!section.isFinished(forKey: key))
        #expect(await appModel.publisherChapters.cachedEntry(episodeID: Self.episodeID)?.chapters.count == 2)
    }

    @Test("A refresh that moves the key leaves the new key unfinished until its own load settles")
    func finishedBelongsToTheLoadKey() async throws {
        let client = StubOpenCastHTTPClient(responses: [.body(Self.document)])
        let fixture = try await OpenCastSystemActionFixture.make(httpClient: client)
        let section = EpisodePublisherChaptersSectionModel()
        let undeclared = try await Self.cacheEpisode(
            declaringDocument: false,
            in: fixture.model,
            cachedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let firstKey = section.loadKey(episode: undeclared)
        await section.load(appModel: fixture.model, episode: undeclared, key: firstKey)
        #expect(section.isFinished(forKey: firstKey))

        // A feed refresh declares a document, which moves the row's stamp.
        let declared = try await Self.cacheEpisode(
            declaringDocument: true,
            in: fixture.model,
            cachedAt: Date(timeIntervalSinceReferenceDate: 800_000_060)
        )
        let secondKey = section.loadKey(episode: declared)
        #expect(secondKey != firstKey)
        #expect(!section.isFinished(forKey: secondKey))
        #expect(section.isFinished(forKey: firstKey))

        await section.load(appModel: fixture.model, episode: declared, key: secondKey)

        #expect(section.isFinished(forKey: secondKey))
        #expect(!section.isFinished(forKey: firstKey))
        #expect(section.chapters(for: Self.episodeID).count == 2)
        #expect(client.requestCount == 1)
    }

    @Test("The load key follows the episode row's cache stamp")
    func loadKeyFollowsCacheStamp() {
        let section = EpisodePublisherChaptersSectionModel()
        let cachedAt = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
        let episode = EpisodeListItemSnapshot(
            episode: Episode(
                id: EpisodeID(rawValue: Self.episodeID),
                podcastID: PodcastID(rawValue: Self.chapteredFeedURL),
                podcastTitle: "A Show",
                title: "Section Chaptered"
            ),
            cachedAt: cachedAt
        )

        #expect(section.loadKey(episode: nil) == "missing")
        #expect(section.loadKey(episode: episode) == "\(Self.episodeID)|800000000.5")
    }

    /// The key a load for another episode would run under, with the same
    /// cache stamp, so it differs from this episode's only by the id.
    private static func otherEpisodeKey(of section: EpisodePublisherChaptersSectionModel, cachedAt: Date) -> String {
        section.loadKey(episode: EpisodeListItemSnapshot(
            episode: Episode(
                id: EpisodeID(rawValue: "episode-1"),
                podcastID: PodcastID(rawValue: chapteredFeedURL),
                podcastTitle: "A Show",
                title: "Another Episode"
            ),
            cachedAt: cachedAt
        ))
    }

    private static func cacheEpisode(
        declaringDocument: Bool,
        in model: OpenCastAppModel,
        cachedAt: Date = .now
    ) async throws -> EpisodeListItemSnapshot {
        let podcastID = PodcastID(rawValue: chapteredFeedURL)
        let episode = Episode(
            id: EpisodeID(rawValue: episodeID),
            podcastID: podcastID,
            podcastTitle: "A Show",
            title: "Section Chaptered",
            audioURL: URL(string: "https://example.com/section-chaptered.mp3"),
            chaptersURL: declaringDocument ? URL(string: documentURL) : nil
        )
        try await model.library.localCache.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(id: podcastID, feedURL: URL(string: chapteredFeedURL)!, title: "A Show"),
                episodes: [episode]
            ),
            refreshedAt: .now
        )
        return EpisodeListItemSnapshot(episode: episode, cachedAt: cachedAt)
    }
}
