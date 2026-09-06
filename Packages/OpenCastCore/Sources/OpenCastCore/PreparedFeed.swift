import Foundation
import SQLite3

public struct PreparedFeed: Hashable, Sendable {
    public var podcast: Podcast
    public var completeness: FeedCompleteness
    public var fetchedAt: Date
    public var newFeedURL: URL?
    public let episodes: PreparedEpisodeSource
    public var episodeCount: Int { episodes.count }
    public var isSalvaged: Bool { !completeness.isComplete }

    public init(snapshot: FeedSnapshot) throws {
        podcast = snapshot.podcast
        completeness = snapshot.isSalvaged ? .partial(.malformedXML("Incomplete feed.")) : .complete
        fetchedAt = snapshot.fetchedAt
        newFeedURL = snapshot.newFeedURL
        episodes = try PreparedEpisodeSource(episodes: snapshot.episodes)
    }

    init(podcast: Podcast, completeness: FeedCompleteness, newFeedURL: URL?, episodes: PreparedEpisodeSource) {
        self.podcast = podcast
        self.completeness = completeness
        fetchedAt = .now
        self.newFeedURL = newFeedURL
        self.episodes = episodes
    }

    /// Compatibility/fixture API. Production imports replay bounded batches.
    public func materialized() throws -> FeedSnapshot {
        var result: [Episode] = []
        try episodes.forEachBatch { result.append(contentsOf: $0) }
        return FeedSnapshot(podcast: podcast, episodes: result, fetchedAt: fetchedAt,
                            isSalvaged: isSalvaged, newFeedURL: newFeedURL)
    }

    /// Identity reconciliation needs IDs and identity material, never summaries
    /// or show notes. Build that projection away from the main actor.
    @concurrent
    public func identitySnapshot() async throws -> FeedSnapshot {
        var result: [Episode] = []
        try episodes.forEachBatch { batch in
            for var episode in batch {
                episode.summary = nil
                episode.showNotesHTML = nil
                result.append(episode)
            }
        }
        return FeedSnapshot(podcast: podcast, episodes: result, fetchedAt: fetchedAt,
                            isSalvaged: isSalvaged, newFeedURL: newFeedURL)
    }
}

public struct PreparedFeedOutcome: Sendable {
    public var feed: PreparedFeed?
    public var finalURL: URL?
    public var validators: FeedValidators?
    public var newFeedURL: URL? { feed?.newFeedURL }

    public init(feed: PreparedFeed?, finalURL: URL? = nil, validators: FeedValidators? = nil) {
        self.feed = feed
        self.finalURL = finalURL
        self.validators = validators
    }
}

/// Read-only, replayable SQLite source with independent readers and shared
/// lifetime ownership. No catalog text is retained by this object.
public final class PreparedEpisodeSource: Hashable, Sendable {
    public static func == (lhs: PreparedEpisodeSource, rhs: PreparedEpisodeSource) -> Bool { lhs.url == rhs.url }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }

    public let count: Int
    public let newestPublishedAt: Date?
    let url: URL
    private let workspace: FeedWorkspace

    init(url: URL, workspace: FeedWorkspace, count: Int, newestPublishedAt: Date?) {
        self.url = url
        self.workspace = workspace
        self.count = count
        self.newestPublishedAt = newestPublishedAt
    }

    convenience init(episodes: [Episode]) throws {
        let workspace = try FeedWorkspace()
        let url = workspace.file("episodes.sqlite")
        let db = try FeedStagingDatabase(url: url)
        try db.execute("CREATE TABLE episodes(position INTEGER PRIMARY KEY, payload BLOB NOT NULL); BEGIN;")
        let insert = try db.statement("INSERT INTO episodes(payload) VALUES (?)")
        defer { sqlite3_finalize(insert) }
        let encoder = JSONEncoder()
        for episode in episodes {
            try Task.checkCancellation()
            try db.bind(encoder.encode(episode), to: insert, at: 1)
            _ = try db.step(insert)
            db.reset(insert)
        }
        try db.execute("COMMIT")
        self.init(url: url, workspace: workspace, count: episodes.count,
                  newestPublishedAt: episodes.compactMap(\.publishedAt).max())
    }

    /// Synchronous for use inside the cache actor's single import transaction.
    /// Each callback owns at most 256 rows / approximately 1 MiB of text; a
    /// single larger item runs alone. Throwing (including cancellation) stops
    /// replay immediately and closes its reader.
    public func forEachBatch(_ consume: ([Episode]) throws -> Void) throws {
        let db = try FeedStagingDatabase(url: url, readOnly: true)
        let select = try db.statement("SELECT payload FROM episodes ORDER BY position")
        defer { sqlite3_finalize(select) }
        let decoder = JSONDecoder()
        var batch: [Episode] = []
        var textBytes = 0
        while try db.step(select) {
            try Task.checkCancellation()
            let episode = try decoder.decode(Episode.self, from: db.data(select, column: 0))
            var size = episode.title.utf8.count + (episode.summary?.utf8.count ?? 0)
                + (episode.showNotesHTML?.utf8.count ?? 0)
            size += episode.podcastTitle.utf8.count + (episode.guid?.utf8.count ?? 0)
            size += episode.id.rawValue.utf8.count + episode.podcastID.rawValue.utf8.count
            size += (episode.audioURL?.absoluteString.utf8.count ?? 0)
                + (episode.artworkURL?.absoluteString.utf8.count ?? 0)
                + (episode.chaptersURL?.absoluteString.utf8.count ?? 0)
            if !batch.isEmpty, textBytes + size > FeedResourcePolicy.importBatchTextBytes {
                try consume(batch)
                batch.removeAll(keepingCapacity: true)
                textBytes = 0
            }
            batch.append(episode)
            textBytes += size
            if batch.count == FeedResourcePolicy.importBatchRows || textBytes >= FeedResourcePolicy.importBatchTextBytes {
                try consume(batch)
                batch.removeAll(keepingCapacity: true)
                textBytes = 0
            }
        }
        try Task.checkCancellation()
        if !batch.isEmpty { try consume(batch) }
    }
}
