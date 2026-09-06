import CryptoKit
import Foundation
import SQLite3

/// Two disk-backed passes preserve the material-dedup and natural-ID winner
/// rules without keeping item text or collision groups in memory.
final class RSSItemStager {
    let url: URL
    let workspace: FeedWorkspace
    private let db: FeedStagingDatabase
    private let insert: OpaquePointer
    private let encoder = JSONEncoder()
    private let podcastID: PodcastID

    init(feedURL: URL, workspace: FeedWorkspace, name: String) throws {
        self.workspace = workspace
        url = workspace.file(name)
        podcastID = URLCanonicalizer.podcastID(for: feedURL)
        db = try FeedStagingDatabase(url: url)
        try db.execute("""
            CREATE TABLE items(position INTEGER PRIMARY KEY, material TEXT UNIQUE, natural TEXT NOT NULL,
                date_missing INTEGER, date REAL, audio_missing INTEGER, audio TEXT, payload BLOB NOT NULL);
            CREATE INDEX winners ON items(natural, date_missing, date, audio_missing, audio, position);
            CREATE TABLE episodes(position INTEGER PRIMARY KEY, id TEXT UNIQUE, payload BLOB NOT NULL);
            BEGIN;
            """)
        insert = try db.statement("""
            INSERT OR IGNORE INTO items(material,natural,date_missing,date,audio_missing,audio,payload)
            VALUES (?,?,?,?,?,?,?)
            """)
    }

    deinit { sqlite3_finalize(insert) }

    func append(_ item: ItemAccumulator) throws {
        try Task.checkCancellation()
        let title = item.title.nonblank ?? "Untitled Episode"
        let material = [item.guid.nonblank ?? "", item.audioURL?.absoluteString ?? "", title,
                        item.publishedAt.map { String($0.timeIntervalSince1970) } ?? ""].joined(separator: "|")
        let materialHash = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        let natural = EpisodeIdentity.makeID(canonicalFeedURL: podcastID.rawValue, guid: item.guid.nonblank,
                                             audioURL: item.audioURL, title: title, publishedAt: item.publishedAt)
        defer { db.reset(insert) }
        try db.bind(materialHash, to: insert, at: 1)
        try db.bind(natural.rawValue, to: insert, at: 2)
        sqlite3_bind_int(insert, 3, item.publishedAt == nil ? 1 : 0)
        sqlite3_bind_double(insert, 4, item.publishedAt?.timeIntervalSince1970 ?? 0)
        sqlite3_bind_int(insert, 5, item.audioURL == nil ? 1 : 0)
        try db.bind(item.audioURL?.absoluteString, to: insert, at: 6)
        try db.bind(encoder.encode(item), to: insert, at: 7)
        _ = try db.step(insert)
    }

    func finish(podcast: Podcast) throws -> PreparedEpisodeSource {
        let rows = try db.statement("SELECT position,natural,payload FROM items ORDER BY position")
        let winner = try db.statement("""
            SELECT position FROM items WHERE natural=?
            ORDER BY date_missing,date,audio_missing,audio,position LIMIT 1
            """)
        let seen = try db.statement("SELECT 1 FROM episodes WHERE id=?")
        let save = try db.statement("INSERT INTO episodes(position,id,payload) VALUES (?,?,?)")
        defer { [rows, winner, seen, save].forEach { sqlite3_finalize($0) } }
        let decoder = JSONDecoder()
        var count = 0
        var newest: Date?
        while try db.step(rows) {
            try Task.checkCancellation()
            let position = sqlite3_column_int64(rows, 0)
            let natural = String(cString: sqlite3_column_text(rows, 1))
            let item = try decoder.decode(ItemAccumulator.self, from: db.data(rows, column: 2))
            let title = item.title.nonblank ?? "Untitled Episode"
            try db.bind(natural, to: winner, at: 1)
            _ = try db.step(winner)
            let isWinner = sqlite3_column_int64(winner, 0) == position
            db.reset(winner)
            var candidates: [EpisodeID] = isWinner ? [EpisodeID(rawValue: natural)] : []
            let guid = item.guid.nonblank
            if guid != nil, item.audioURL != nil {
                candidates.append(EpisodeIdentity.makeID(canonicalFeedURL: podcastID.rawValue, guid: nil,
                    audioURL: item.audioURL, title: title, publishedAt: item.publishedAt))
            }
            if guid != nil || item.audioURL != nil {
                candidates.append(EpisodeIdentity.makeID(canonicalFeedURL: podcastID.rawValue, guid: nil,
                    audioURL: nil, title: title, publishedAt: item.publishedAt))
            }
            var chosen: EpisodeID?
            for candidate in candidates {
                try db.bind(candidate.rawValue, to: seen, at: 1)
                let exists = try db.step(seen)
                db.reset(seen)
                if !exists { chosen = candidate; break }
            }
            guard let chosen else { continue }
            let episode = Episode(id: chosen, podcastID: podcastID, podcastTitle: podcast.title, title: title,
                summary: item.summary.nonblank, showNotesHTML: item.showNotesHTML.nonblank ?? item.summary.nonblank,
                publishedAt: item.publishedAt, duration: item.duration, audioURL: item.audioURL,
                artworkURL: item.artworkURL ?? podcast.artworkURL, guid: guid, chaptersURL: item.chaptersURL)
            sqlite3_bind_int64(save, 1, position)
            try db.bind(chosen.rawValue, to: save, at: 2)
            try db.bind(encoder.encode(episode), to: save, at: 3)
            _ = try db.step(save)
            db.reset(save)
            count += 1
            if let date = item.publishedAt, newest == nil || date > newest! { newest = date }
        }
        // Finalize the raw reader before dropping its table.
        sqlite3_reset(rows)
        try db.execute("DROP TABLE items; COMMIT;")
        return PreparedEpisodeSource(url: url, workspace: workspace, count: count, newestPublishedAt: newest)
    }
}

private extension Optional where Wrapped == String {
    var nonblank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
