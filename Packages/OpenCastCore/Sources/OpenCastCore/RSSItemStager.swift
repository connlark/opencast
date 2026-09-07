import CryptoKit
import Foundation
import SQLite3

/// Two disk-backed passes preserve the material-dedup and natural-ID winner
/// rules without keeping item text or collision groups in memory. Scratch
/// rows and the published replay database have independent workspaces so the
/// former can disappear as soon as winner selection completes.
final class RSSItemStager {
    private let workspace: FeedWorkspace
    private var db: FeedStagingDatabase?
    private var insert: OpaquePointer?
    private let encoder = JSONEncoder()
    private let podcastID: PodcastID

    init(feedURL: URL) throws {
        workspace = try FeedWorkspace()
        podcastID = URLCanonicalizer.podcastID(for: feedURL)
        let db = try FeedStagingDatabase(url: workspace.file("items.sqlite"))
        do {
            try db.execute("""
                CREATE TABLE items(position INTEGER PRIMARY KEY, material TEXT UNIQUE, natural TEXT NOT NULL,
                    date_missing INTEGER, date REAL, audio_missing INTEGER, audio TEXT, payload BLOB NOT NULL);
                CREATE INDEX winners ON items(natural, date_missing, date, audio_missing, audio, position);
                CREATE TABLE assigned_ids(id TEXT PRIMARY KEY);
                BEGIN;
                """)
            insert = try db.statement("""
                INSERT OR IGNORE INTO items(material,natural,date_missing,date,audio_missing,audio,payload)
                VALUES (?,?,?,?,?,?,?)
                """)
            self.db = db
        } catch {
            db.close()
            workspace.discard()
            throw error
        }
    }

    deinit {
        discard()
    }

    func append(_ item: ItemAccumulator) throws {
        try Task.checkCancellation()
        guard let db, let insert else {
            throw CocoaError(.fileWriteUnknown)
        }
        let title = item.title.nonblank ?? "Untitled Episode"
        let material = [
            item.guid.nonblank ?? "",
            item.audioURL?.absoluteString ?? "",
            title,
            item.publishedAt.map { String($0.timeIntervalSince1970) } ?? ""
        ].joined(separator: "|")
        let materialHash = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let natural = EpisodeIdentity.makeID(
            canonicalFeedURL: podcastID.rawValue,
            guid: item.guid.nonblank,
            audioURL: item.audioURL,
            title: title,
            publishedAt: item.publishedAt
        )
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
        try Task.checkCancellation()
        guard let rawDB = db else {
            throw CocoaError(.fileReadUnknown)
        }
        finalizeInsert()
        try rawDB.execute("COMMIT; BEGIN;")

        let outputWorkspace = try FeedWorkspace()
        let outputURL = outputWorkspace.file("episodes.sqlite")
        let outputDB: FeedStagingDatabase
        do {
            outputDB = try FeedStagingDatabase(url: outputURL)
            try outputDB.execute(
                "CREATE TABLE episodes(position INTEGER PRIMARY KEY, payload BLOB NOT NULL); BEGIN;"
            )
        } catch {
            outputWorkspace.discard()
            discard()
            throw error
        }

        var statements: [OpaquePointer] = []
        do {
            let rows = try rawDB.statement("SELECT position,natural,payload FROM items ORDER BY position")
            statements.append(rows)
            let winner = try rawDB.statement("""
                SELECT position FROM items WHERE natural=?
                ORDER BY date_missing,date,audio_missing,audio,position LIMIT 1
                """)
            statements.append(winner)
            let seen = try rawDB.statement("SELECT 1 FROM assigned_ids WHERE id=?")
            statements.append(seen)
            let assign = try rawDB.statement("INSERT INTO assigned_ids(id) VALUES (?)")
            statements.append(assign)
            let save = try outputDB.statement("INSERT INTO episodes(position,payload) VALUES (?,?)")
            statements.append(save)

            let decoder = JSONDecoder()
            var count = 0
            var newest: Date?
            while try rawDB.step(rows) {
                try Task.checkCancellation()
                let position = sqlite3_column_int64(rows, 0)
                let natural = String(cString: sqlite3_column_text(rows, 1))
                let item = try decoder.decode(
                    ItemAccumulator.self,
                    from: rawDB.data(rows, column: 2)
                )
                let title = item.title.nonblank ?? "Untitled Episode"
                try rawDB.bind(natural, to: winner, at: 1)
                _ = try rawDB.step(winner)
                let isWinner = sqlite3_column_int64(winner, 0) == position
                rawDB.reset(winner)

                var candidates: [EpisodeID] = isWinner ? [EpisodeID(rawValue: natural)] : []
                let guid = item.guid.nonblank
                if guid != nil, item.audioURL != nil {
                    candidates.append(EpisodeIdentity.makeID(
                        canonicalFeedURL: podcastID.rawValue,
                        guid: nil,
                        audioURL: item.audioURL,
                        title: title,
                        publishedAt: item.publishedAt
                    ))
                }
                if guid != nil || item.audioURL != nil {
                    candidates.append(EpisodeIdentity.makeID(
                        canonicalFeedURL: podcastID.rawValue,
                        guid: nil,
                        audioURL: nil,
                        title: title,
                        publishedAt: item.publishedAt
                    ))
                }

                var chosen: EpisodeID?
                for candidate in candidates {
                    try rawDB.bind(candidate.rawValue, to: seen, at: 1)
                    let exists = try rawDB.step(seen)
                    rawDB.reset(seen)
                    if !exists {
                        chosen = candidate
                        break
                    }
                }
                guard let chosen else { continue }

                let episode = Episode(
                    id: chosen,
                    podcastID: podcastID,
                    podcastTitle: podcast.title,
                    title: title,
                    summary: item.summary.nonblank,
                    showNotesHTML: item.showNotesHTML.nonblank ?? item.summary.nonblank,
                    publishedAt: item.publishedAt,
                    duration: item.duration,
                    audioURL: item.audioURL,
                    artworkURL: item.artworkURL ?? podcast.artworkURL,
                    guid: guid,
                    chaptersURL: item.chaptersURL
                )
                sqlite3_bind_int64(save, 1, position)
                try outputDB.bind(encoder.encode(episode), to: save, at: 2)
                _ = try outputDB.step(save)
                outputDB.reset(save)

                try rawDB.bind(chosen.rawValue, to: assign, at: 1)
                _ = try rawDB.step(assign)
                rawDB.reset(assign)
                count += 1
                if let date = item.publishedAt, newest == nil || date > newest! {
                    newest = date
                }
            }
            try Task.checkCancellation()
            statements.forEach { sqlite3_finalize($0) }
            statements.removeAll()
            try outputDB.execute("COMMIT;")
            try rawDB.execute("COMMIT;")
            outputDB.close()
            rawDB.close()
            db = nil
            workspace.discard()
            return PreparedEpisodeSource(
                url: outputURL,
                workspace: outputWorkspace,
                count: count,
                newestPublishedAt: newest
            )
        } catch {
            statements.forEach { sqlite3_finalize($0) }
            try? outputDB.execute("ROLLBACK;")
            try? rawDB.execute("ROLLBACK;")
            outputDB.close()
            outputWorkspace.discard()
            discard()
            throw error
        }
    }

    func discard() {
        finalizeInsert()
        if let db {
            try? db.execute("ROLLBACK;")
            db.close()
            self.db = nil
        }
        workspace.discard()
    }

    private func finalizeInsert() {
        guard let insert else { return }
        sqlite3_finalize(insert)
        self.insert = nil
    }
}

private extension Optional where Wrapped == String {
    var nonblank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
