import Intents
import Testing
@testable import OpenCast

@Suite("Siri media resolver")
struct SiriMediaResolverTests {
    private let subscriptions = [
        SiriMediaSubscription(podcastID: "security", title: "Security Now"),
        SiriMediaSubscription(podcastID: "cafe", title: "Café Tech"),
        SiriMediaSubscription(podcastID: "daily", title: "Daily Tech News")
    ]

    @Test("Show matching handles exact, case, diacritics, and partial tokens")
    func showMatching() async {
        #expect(await resolve("Security Now") == .show(podcastID: "security"))
        #expect(await resolve("SECURITY NOW") == .show(podcastID: "security"))
        #expect(await resolve("CAFE TECH") == .show(podcastID: "cafe"))
        #expect(await resolve("secur now") == .show(podcastID: "security"))
    }

    @Test("The best show match wins and an exact prefix beats a substring")
    func bestShowMatch() async {
        let candidates = subscriptions + [
            SiriMediaSubscription(podcastID: "daily-short", title: "Daily")
        ]

        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Daily Tech",
                mediaType: .podcastShow,
                subscriptions: candidates,
                episodes: []
            ) == .show(podcastID: "daily")
        )
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Daily",
                mediaType: .podcastShow,
                subscriptions: candidates,
                episodes: []
            ) == .show(podcastID: "daily-short")
        )
    }

    @Test("A unique episode title match resolves to the episode")
    func episodeTitleMatch() async {
        let episodes = [
            episode(id: "one", show: "Security Now", title: "The Passwordless Future"),
            episode(id: "two", show: "Café Tech", title: "Coffee and Robots")
        ]

        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Passwordless Future",
                mediaType: .podcastEpisode,
                subscriptions: [],
                episodes: episodes
            ) == .episode(episodeID: "one")
        )
    }

    @Test("A show match takes precedence over an episode match")
    func showBeatsEpisode() async {
        let episodes = [
            episode(id: "episode", show: "Other Show", title: "Security Now")
        ]

        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Security Now",
                mediaType: .podcastEpisode,
                subscriptions: subscriptions,
                episodes: episodes
            ) == .show(podcastID: "security")
        )
    }

    @Test("Generic requests resume")
    func genericRequest() async {
        #expect(await resolve(nil) == .resume)
        #expect(await resolve("   ") == .resume)
    }

    @Test("Unknown, ambiguous, unsupported, and empty-library requests do not match")
    func noMatch() async {
        let ambiguousEpisodes = [
            episode(id: "one", show: "One", title: "CarPlay Roundtable"),
            episode(id: "two", show: "Two", title: "CarPlay Roundtable")
        ]

        #expect(await resolve("gibberish") == .noMatch)
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "CarPlay Roundtable",
                mediaType: .podcastEpisode,
                subscriptions: [],
                episodes: ambiguousEpisodes
            ) == .noMatch
        )
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Security Now",
                mediaType: .song,
                subscriptions: subscriptions,
                episodes: []
            ) == .noMatch
        )
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Security Now",
                mediaType: .podcastShow,
                subscriptions: [],
                episodes: []
            ) == .noMatch
        )
    }

    @Test("A large episode catalogue resolves deterministically without a candidate cap")
    func largeCatalogue() async {
        var episodes = (0..<4_000).map { index in
            episode(
                id: "catalogue-\(index)",
                show: "Archive Show",
                title: "Archive Episode \(index)"
            )
        }
        episodes.append(
            episode(
                id: "old-target",
                show: "Archive Show",
                title: "The Forgotten Satellite"
            )
        )

        let first = await SiriMediaResolver.resolve(
            mediaName: "Forgotten Satellite",
            mediaType: .podcastEpisode,
            subscriptions: [],
            episodes: episodes
        )
        let second = await SiriMediaResolver.resolve(
            mediaName: "Forgotten Satellite",
            mediaType: .podcastEpisode,
            subscriptions: [],
            episodes: episodes
        )

        #expect(first == .episode(episodeID: "old-target"))
        #expect(second == first)
    }

    private func resolve(_ name: String?) async -> SiriMediaResolution {
        await SiriMediaResolver.resolve(
            mediaName: name,
            mediaType: .unknown,
            subscriptions: subscriptions,
            episodes: []
        )
    }

    private func episode(id: String, show: String, title: String) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: id,
            podcastID: "https://example.com/\(id).xml",
            podcastTitle: show,
            title: title,
            summary: nil,
            publishedAt: nil,
            duration: 60,
            audioURL: "https://example.com/\(id).mp3",
            artworkURL: nil,
            artworkPreview: nil,
            guid: id,
            cachedAt: .now
        )
    }
}
