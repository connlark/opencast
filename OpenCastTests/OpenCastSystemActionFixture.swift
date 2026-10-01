import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
struct OpenCastSystemActionFixture {
    static let feed = "https://example.com/actions.xml"
    let model: OpenCastAppModel
    let context: ModelContext

    static func make(episodeCount: Int = 3, queue: UpNextQueueStore? = nil, downloads: DownloadStore? = nil, playlists: PlaylistStore? = nil) async throws -> Self {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SubscriptionRecord(feedURL: feed, title: "A Show"))
        try context.save()
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let id = PodcastID(rawValue: feed)
        let episodes = (0..<episodeCount).map { number in
            Episode(id: EpisodeID(rawValue: "episode-\(number)"), podcastID: id, podcastTitle: "A Show", title: "Shared Title", publishedAt: Date(timeIntervalSince1970: Double(number)), duration: 120, audioURL: number == 0 ? nil : URL(string: "https://example.com/\(number).mp3"))
        }
        try await cache.upsertCache(from: FeedSnapshot(podcast: Podcast(id: id, feedURL: URL(string: feed)!, title: "A Show"), episodes: episodes), refreshedAt: .now)
        let model = OpenCastAppModel(localLibraryCacheStore: cache, downloads: downloads ?? DownloadStore(), upNextQueue: queue ?? UpNextQueueStore(), playlists: playlists ?? PlaylistStore(), allowsAutomaticFeedRefresh: false)
        return Self(model: model, context: context)
    }

    /// Inserts four playlists and saves; call it before the first `perform`,
    /// because the rows reach the store only through hydration. "All Played"
    /// holds `episode-0` rather than a Commute episode, since played state is
    /// per episode and Commute must stay fully unplayed.
    func seedPlaylists() async throws -> SeededPlaylists {
        let seeded = SeededPlaylists(
            commuteID: "playlist-commute",
            allPlayedID: "playlist-all-played",
            emptyID: "playlist-empty",
            smartID: "playlist-smart"
        )
        let updatedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let playlists: [(id: String, name: String, kind: PlaylistKind, episodeIDs: [String])] = [
            (seeded.commuteID, "Commute", .manual, ["episode-1", "episode-2"]),
            (seeded.allPlayedID, "All Played", .manual, ["episode-0"]),
            (seeded.emptyID, "Empty", .manual, []),
            (seeded.smartID, "Unplayed Smart", .smart, [])
        ]
        for (index, playlist) in playlists.enumerated() {
            // Distinct, descending dates give a known "most recently updated" order.
            let date = updatedAt.addingTimeInterval(Double(index) * -60)
            context.insert(
                PlaylistRecord(
                    playlistID: playlist.id,
                    name: playlist.name,
                    kind: playlist.kind,
                    ruleJSON: playlist.kind == .smart ? PlaylistRule.default.normalized().encodedJSON() : nil,
                    createdAt: date,
                    updatedAt: date
                )
            )
            let sortKeys = PlaylistSortKey.renumbered(count: playlist.episodeIDs.count)
            for (position, episodeID) in playlist.episodeIDs.enumerated() {
                context.insert(
                    PlaylistItemRecord(
                        playlistID: playlist.id,
                        episodeID: episodeID,
                        podcastID: Self.feed,
                        sortKey: sortKeys[position],
                        addedAt: date,
                        updatedAt: date,
                        episodeTitle: "Shared Title",
                        podcastTitle: "A Show",
                        duration: 120
                    )
                )
            }
        }
        context.insert(EpisodeProgressRecord(episodeID: "episode-0", podcastID: Self.feed, isPlayed: true, updatedAt: updatedAt))
        try context.save()
        return seeded
    }
}

nonisolated struct SeededPlaylists: Sendable {
    let commuteID: String
    let allPlayedID: String
    let emptyID: String
    let smartID: String
}
