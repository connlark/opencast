import Foundation
import SQLite3

nonisolated struct SQLiteEpisodeSearchDocument: Sendable {
    let episodeID: String
    let podcastID: String
    let title: String
    let podcastTitle: String
    let summary: String
    let showNotes: String
    let titleCanonical: String
    let podcastTitleCanonical: String

    init(
        episodeID: String,
        podcastID: String,
        title: String,
        podcastTitle: String,
        summaryHTML: String?,
        showNotesHTML: String?
    ) {
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.title = title
        self.podcastTitle = podcastTitle
        summary = summaryHTML.map(HTMLPlainText.collapsedText(from:)) ?? ""
        showNotes = showNotesHTML.map(HTMLPlainText.collapsedText(from:)) ?? ""
        titleCanonical = SearchTextNormalization.canonicalSearchText(title)
        podcastTitleCanonical = SearchTextNormalization.canonicalSearchText(
            podcastTitle
        )
    }
}

nonisolated enum SQLiteEpisodeSearchIndex {
    static let schemaVersion = 6
    static let contentVersion = 12
    static let rebuildBatchSize = 50

    static let tableName = "episode_search_fts"
    static let transcriptTableName = "episode_transcript_search_fts"
    static let transcriptSegmentTableName =
        "episode_transcript_search_segment"
    static let spellingDocumentTableName =
        "episode_search_spelling_document"
    static let evidenceTableName = "episode_search_evidence"
    static let evidenceBodyTableName = "episode_search_evidence_body"
    static let metadataVocabularyColumnTableName =
        "episode_search_fts_vocabulary_column"
    static let metadataVocabularyInstanceTableName =
        "episode_search_fts_vocabulary_instance"
    static let transcriptVocabularyColumnTableName =
        "episode_transcript_search_fts_vocabulary_column"
    static let transcriptVocabularyInstanceTableName =
        "episode_transcript_search_fts_vocabulary_instance"
    static let metadataVocabularySource = 0
    static let transcriptVocabularySource = 1
    static let vocabularyDeleteTableName =
        "episode_search_vocabulary_delete"
    static let contentVersionKey = "episode_search_content_version"
    static let candidateLimit = 100
    static let relaxedCandidateThreshold = 20
    static let transcriptCandidateLimit = 200

    static func ensureSchema(in db: OpaquePointer) throws {
        if try databaseSchemaVersion(in: db) < schemaVersion {
            try execute(
                """
                DROP TABLE IF EXISTS episode_search_fts_vocabulary_column;
                DROP TABLE IF EXISTS episode_search_fts_vocabulary_instance;
                DROP TABLE IF EXISTS episode_transcript_search_fts_vocabulary_column;
                DROP TABLE IF EXISTS episode_transcript_search_fts_vocabulary_instance;
                DROP TABLE IF EXISTS episode_search_vocabulary_document;
                DROP TABLE IF EXISTS episode_search_vocabulary_delete;
                DROP TABLE IF EXISTS episode_search_spelling_document;
                DROP TABLE IF EXISTS episode_search_evidence;
                DROP TABLE IF EXISTS episode_search_evidence_body;
                DROP TABLE IF EXISTS episode_transcript_search_segment;
                DROP TABLE IF EXISTS episode_search_fts;
                DROP TABLE IF EXISTS episode_transcript_search_fts;
                """,
                operation: "episode search schema migration",
                db: db
            )
        }
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS episode_search_fts USING fts5(
              title,
              podcast_title,
              summary,
              show_notes,
              content = '',
              contentless_delete = 1,
              tokenize = 'unicode61 remove_diacritics 2',
              detail = column
            )
            """,
            operation: "episode search schema",
            db: db
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS episode_transcript_search_fts
            USING fts5(
              text,
              content = '',
              contentless_delete = 1,
              tokenize = 'unicode61 remove_diacritics 2',
              detail = column
            )
            """,
            operation: "episode transcript search schema",
            db: db
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episode_search_spelling_document (
              episode_id TEXT NOT NULL,
              source INTEGER NOT NULL,
              terms_data BLOB NOT NULL,
              PRIMARY KEY (episode_id, source)
            ) WITHOUT ROWID
            """,
            operation: "episode search spelling schema",
            db: db
        )
        // The canonical visible-title columns and the compressed body blob
        // live in separate tables: the per-keystroke scans read only the two
        // short canonicals for up to every evidence row, and a same-record
        // body blob would inflate every page those scans touch (and push the
        // canonicals into overflow chains). body_data is read only for the
        // top hits via materializeBodyEvidence.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episode_search_evidence (
              search_rowid INTEGER PRIMARY KEY,
              title_canonical TEXT NOT NULL DEFAULT '',
              podcast_title_canonical TEXT NOT NULL DEFAULT ''
            )
            """,
            operation: "episode search evidence schema",
            db: db
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episode_search_evidence_body (
              search_rowid INTEGER PRIMARY KEY,
              body_data BLOB
            )
            """,
            operation: "episode search evidence schema",
            db: db
        )
        // Installed builds created an (episode_id) index on the segment
        // table; the UNIQUE (episode_id, segment_id) autoindex already leads
        // with episode_id, so it only amplified every segment write.
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episode_transcript_search_segment (
              search_rowid INTEGER PRIMARY KEY,
              segment_id TEXT NOT NULL,
              episode_id TEXT NOT NULL,
              podcast_id TEXT NOT NULL,
              transcript_version TEXT NOT NULL,
              start_seconds REAL NOT NULL,
              end_seconds REAL NOT NULL,
              text TEXT NOT NULL DEFAULT '',
              UNIQUE (episode_id, segment_id)
            );

            DROP INDEX IF EXISTS episode_transcript_search_segment_episode;

            CREATE INDEX IF NOT EXISTS
              episode_transcript_search_segment_podcast
            ON episode_transcript_search_segment (podcast_id, episode_id);
            """,
            operation: "episode transcript search schema",
            db: db
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS
              episode_search_fts_vocabulary_column
            USING fts5vocab(episode_search_fts, 'col');

            CREATE VIRTUAL TABLE IF NOT EXISTS
              episode_search_fts_vocabulary_instance
            USING fts5vocab(episode_search_fts, 'instance');

            CREATE VIRTUAL TABLE IF NOT EXISTS
              episode_transcript_search_fts_vocabulary_column
            USING fts5vocab(episode_transcript_search_fts, 'col');

            CREATE VIRTUAL TABLE IF NOT EXISTS
              episode_transcript_search_fts_vocabulary_instance
            USING fts5vocab(episode_transcript_search_fts, 'instance');
            """,
            operation: "episode search vocabulary schema",
            db: db
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS episode_search_vocabulary_delete (
              delete_key TEXT NOT NULL,
              term TEXT NOT NULL,
              PRIMARY KEY (delete_key, term)
            ) WITHOUT ROWID
            """,
            operation: "episode search vocabulary schema",
            db: db
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS episode_search_vocabulary_delete_term
            ON episode_search_vocabulary_delete (term)
            """,
            operation: "episode search vocabulary schema",
            db: db
        )
        // The index owns PRAGMA user_version: the stamp lands only once
        // every table above exists, so a failed open retries the migration.
        if try databaseSchemaVersion(in: db) < schemaVersion {
            try execute(
                "PRAGMA user_version = \(schemaVersion)",
                operation: "episode search schema migration",
                db: db
            )
        }
    }

    static func storedContentVersion(in db: OpaquePointer) throws -> Int? {
        var value: Int?
        try query(
            "SELECT value FROM local_cache_meta WHERE key = ? LIMIT 1",
            operation: "episode search version load",
            db: db,
            bindings: { statement in
                try bind(
                    contentVersionKey,
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search version load"
                )
            }
        ) { statement in
            value = columnText(statement, 0).flatMap(Int.init)
        }
        return value
    }

    static func markNeedsRebuild(in db: OpaquePointer) throws {
        try setStoredContentVersion("rebuilding", in: db)
    }

    static func markReady(in db: OpaquePointer) throws {
        try setStoredContentVersion(String(contentVersion), in: db)
    }

    static func clear(in db: OpaquePointer) throws {
        try execute(
            "DELETE FROM episode_search_fts",
            operation: "episode search clear",
            db: db
        )
        try execute(
            "DELETE FROM \(vocabularyDeleteTableName)",
            operation: "episode search vocabulary clear",
            db: db
        )
        try execute(
            "DELETE FROM \(spellingDocumentTableName)",
            operation: "episode search spelling clear",
            db: db
        )
        try execute(
            "DELETE FROM \(evidenceTableName)",
            operation: "episode search evidence clear",
            db: db
        )
        try execute(
            "DELETE FROM \(evidenceBodyTableName)",
            operation: "episode search evidence clear",
            db: db
        )
        try execute(
            "DELETE FROM \(transcriptTableName)",
            operation: "episode transcript search clear",
            db: db
        )
        try execute(
            "DELETE FROM \(transcriptSegmentTableName)",
            operation: "episode transcript search clear",
            db: db
        )
    }


    static func isConsistent(in db: OpaquePointer) throws -> Bool {
        let canonicalCount = try rowCount(
            table: "episode_cache",
            distinctEpisodeIDs: false,
            db: db
        )
        let indexedCount = try rowCount(
            table: tableName,
            distinctEpisodeIDs: false,
            db: db
        )
        let evidenceCount = try rowCount(
            table: evidenceTableName,
            distinctEpisodeIDs: false,
            db: db
        )
        let evidenceBodyCount = try rowCount(
            table: evidenceBodyTableName,
            distinctEpisodeIDs: false,
            db: db
        )
        var joinedCount = 0
        try query(
            """
            SELECT COUNT(*)
            FROM episode_search_fts
            JOIN episode_cache
              ON episode_cache.rowid = episode_search_fts.rowid
            """,
            operation: "episode search consistency",
            db: db
        ) { statement in
            joinedCount = Int(sqlite3_column_int64(statement, 0))
        }
        var joinedEvidenceCount = 0
        try query(
            """
            SELECT COUNT(*)
            FROM episode_search_evidence
            JOIN episode_cache
              ON episode_cache.rowid = episode_search_evidence.search_rowid
            """,
            operation: "episode search evidence consistency",
            db: db
        ) { statement in
            joinedEvidenceCount = Int(sqlite3_column_int64(statement, 0))
        }
        return canonicalCount == indexedCount
            && indexedCount == joinedCount
            && indexedCount == evidenceCount
            && evidenceCount == evidenceBodyCount
            && evidenceCount == joinedEvidenceCount
    }


    private static func rowCount(
        table: String,
        distinctEpisodeIDs: Bool,
        db: OpaquePointer
    ) throws -> Int {
        let projection = distinctEpisodeIDs
            ? "COUNT(DISTINCT episode_id)"
            : "COUNT(*)"
        var count = 0
        try query(
            "SELECT \(projection) FROM \(table)",
            operation: "episode search consistency",
            db: db
        ) { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count
    }

    private static func databaseSchemaVersion(
        in db: OpaquePointer
    ) throws -> Int {
        var version = 0
        try query(
            "PRAGMA user_version",
            operation: "episode search schema version",
            db: db
        ) { statement in
            version = Int(sqlite3_column_int64(statement, 0))
        }
        return version
    }

    private static func setStoredContentVersion(
        _ value: String,
        in db: OpaquePointer
    ) throws {
        try run(
            """
            INSERT OR REPLACE INTO local_cache_meta (key, value)
            VALUES (?, ?)
            """,
            operation: "episode search version update",
            db: db
        ) { statement in
            try bind(
                contentVersionKey,
                at: 1,
                statement: statement,
                db: db,
                operation: "episode search version update"
            )
            try bind(
                value,
                at: 2,
                statement: statement,
                db: db,
                operation: "episode search version update"
            )
        }
    }

}
