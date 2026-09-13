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

    static func make(episodeCount: Int = 3, queue: UpNextQueueStore? = nil, downloads: DownloadStore? = nil) async throws -> Self {
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
        let model = OpenCastAppModel(localLibraryCacheStore: cache, downloads: downloads ?? DownloadStore(), upNextQueue: queue ?? UpNextQueueStore(), allowsAutomaticFeedRefresh: false)
        return Self(model: model, context: context)
    }
}
