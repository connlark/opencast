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

    @Test("A playlist whose name matches exactly beats a show it only prefixes")
    func playlistNameWinsOverSimilarShow() async {
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Commute",
                mediaType: .unknown,
                subscriptions: [SiriMediaSubscription(podcastID: "commute-radio", title: "Commute Radio")],
                episodes: [],
                playlists: [SiriMediaPlaylist(playlistID: "commute", name: "Commute")]
            ) == .playlist(playlistID: "commute")
        )
    }

    @Test("An untyped query scores the playlist against the best show: a tie goes to the playlist")
    func untypedTieGoesToThePlaylist() async {
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Commute",
                mediaType: .unknown,
                subscriptions: [SiriMediaSubscription(podcastID: "commute-show", title: "Commute")],
                episodes: [],
                playlists: [SiriMediaPlaylist(playlistID: "commute", name: "Commute")]
            ) == .playlist(playlistID: "commute")
        )
    }

    @Test("An untyped query keeps an exact show title over a playlist it only prefixes")
    func untypedExactShowBeatsPrefixPlaylist() async {
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Daily",
                mediaType: .unknown,
                subscriptions: [SiriMediaSubscription(podcastID: "daily", title: "Daily")],
                episodes: [],
                playlists: [SiriMediaPlaylist(playlistID: "daily-commute", name: "Daily Commute")]
            ) == .show(podcastID: "daily")
        )
        // The playlist type asks for the playlist first regardless of the show's score.
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Daily",
                mediaType: .podcastPlaylist,
                subscriptions: [SiriMediaSubscription(podcastID: "daily", title: "Daily")],
                episodes: [],
                playlists: [SiriMediaPlaylist(playlistID: "daily-commute", name: "Daily Commute")]
            ) == .playlist(playlistID: "daily-commute")
        )
    }

    @Test("The trailing word is cut from the spoken string, so punctuation keeps its exact-title rank")
    func trailingPlaylistTokenCutKeepsPunctuation() async {
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Mom's Mix playlist",
                mediaType: .unknown,
                subscriptions: [],
                episodes: [],
                playlists: [
                    SiriMediaPlaylist(playlistID: "moms-mix", name: "Mom's Mix"),
                    SiriMediaPlaylist(playlistID: "moms-mixes", name: "Mom's Mixes")
                ]
            ) == .playlist(playlistID: "moms-mix")
        )
    }

    @Test("A trailing \"playlist\" is dropped when the name as spoken finds nothing")
    func trailingPlaylistTokenIsStripped() async {
        let playlists = [SiriMediaPlaylist(playlistID: "commute", name: "Commute")]

        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Commute playlist",
                mediaType: .unknown,
                subscriptions: [],
                episodes: [],
                playlists: playlists
            ) == .playlist(playlistID: "commute")
        )
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Commute Playlist",
                mediaType: .podcastPlaylist,
                subscriptions: [],
                episodes: [],
                playlists: playlists
            ) == .playlist(playlistID: "commute")
        )
    }

    @Test("A playlist-typed request with no playlist match still finds the show")
    func podcastPlaylistTypeWithoutMatchFallsBackToShow() async {
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Commute Radio",
                mediaType: .podcastPlaylist,
                subscriptions: [SiriMediaSubscription(podcastID: "commute-radio", title: "Commute Radio")],
                episodes: [],
                playlists: [SiriMediaPlaylist(playlistID: "weekend", name: "Weekend")]
            ) == .show(podcastID: "commute-radio")
        )
    }

    @Test("Two equally good playlists match neither, and the show search continues")
    func tiedPlaylistsFallThrough() async {
        let playlists = [
            SiriMediaPlaylist(playlistID: "commute-a", name: "Commute"),
            SiriMediaPlaylist(playlistID: "commute-b", name: "Commute")
        ]

        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Commute",
                mediaType: .unknown,
                subscriptions: [],
                episodes: [],
                playlists: playlists
            ) == .noMatch
        )
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Commute",
                mediaType: .unknown,
                subscriptions: [SiriMediaSubscription(podcastID: "commute-radio", title: "Commute Radio")],
                episodes: [],
                playlists: playlists
            ) == .show(podcastID: "commute-radio")
        )
    }

    @Test("A show-typed request never considers playlists")
    func showTypeIgnoresPlaylists() async {
        #expect(
            await SiriMediaResolver.resolve(
                mediaName: "Commute",
                mediaType: .podcastShow,
                subscriptions: [],
                episodes: [],
                playlists: [SiriMediaPlaylist(playlistID: "commute", name: "Commute")]
            ) == .noMatch
        )
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
