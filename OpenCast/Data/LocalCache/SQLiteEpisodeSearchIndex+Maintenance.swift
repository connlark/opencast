import Foundation
import SQLite3

nonisolated extension SQLiteEpisodeSearchIndex {
    static func replace(
        _ documents: [SQLiteEpisodeSearchDocument],
        in db: OpaquePointer
    ) throws {
        guard !documents.isEmpty else {
            return
        }

        let operation = "episode search upsert"
        let delete = try prepare(
            "DELETE FROM episode_search_fts WHERE rowid = ?",
            operation: operation,
            db: db
        )
        defer {
            sqlite3_finalize(delete)
        }
        let insert = try prepare(
            """
            INSERT INTO episode_search_fts (
              rowid, title, podcast_title, summary, show_notes
            ) VALUES (?, ?, ?, ?, ?)
            """,
            operation: operation,
            db: db
        )
        defer {
            sqlite3_finalize(insert)
        }
        let evidenceUpsert = try prepare(
            """
            INSERT INTO episode_search_evidence (
              search_rowid, body_data, title_canonical, podcast_title_canonical
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT (search_rowid) DO UPDATE SET
              body_data = excluded.body_data,
              title_canonical = excluded.title_canonical,
              podcast_title_canonical = excluded.podcast_title_canonical
            """,
            operation: operation,
            db: db
        )
        defer {
            sqlite3_finalize(evidenceUpsert)
        }

        let episodeIDs = documents.map(\.episodeID)
        let rowIDsByEpisodeID = try episodeRowIDsByEpisodeID(
            episodeIDs: episodeIDs,
            db: db
        )
        let oldTerms = try storedVocabularyTerms(
            episodeIDs: episodeIDs,
            source: metadataVocabularySource,
            db: db
        )
        var newTerms: Set<String> = []

        for document in documents {
            guard let rowID = rowIDsByEpisodeID[document.episodeID] else {
                throw LocalLibraryCacheStoreError(
                    operation: operation,
                    message: "canonical episode row is missing"
                )
            }

            let contributions = EpisodeSearchSpelling.contributions([
                (document.title, .title),
                (document.podcastTitle, .podcastTitle),
                (document.summary, .body),
                (document.showNotes, .body),
            ])
            let documentNewTerms = Set(contributions.map(\.term))
            newTerms.formUnion(documentNewTerms)

            try bind(
                rowID,
                at: 1,
                statement: delete,
                db: db,
                operation: operation
            )
            try step(delete, operation: operation, db: db)
            try reset(delete, operation: operation, db: db)

            try bind(
                rowID,
                at: 1,
                statement: insert,
                db: db,
                operation: operation
            )
            try bind(
                document.title,
                at: 2,
                statement: insert,
                db: db,
                operation: operation
            )
            try bind(
                document.podcastTitle,
                at: 3,
                statement: insert,
                db: db,
                operation: operation
            )
            try bind(
                document.summary,
                at: 4,
                statement: insert,
                db: db,
                operation: operation
            )
            try bind(
                document.showNotes,
                at: 5,
                statement: insert,
                db: db,
                operation: operation
            )
            try step(insert, operation: operation, db: db)
            try reset(insert, operation: operation, db: db)

            try bind(
                rowID,
                at: 1,
                statement: evidenceUpsert,
                db: db,
                operation: operation
            )
            try bind(
                compressedSearchEvidence(
                    summary: document.summary,
                    showNotes: document.showNotes
                ),
                at: 2,
                statement: evidenceUpsert,
                db: db,
                operation: operation
            )
            try bind(
                document.titleCanonical,
                at: 3,
                statement: evidenceUpsert,
                db: db,
                operation: operation
            )
            try bind(
                document.podcastTitleCanonical,
                at: 4,
                statement: evidenceUpsert,
                db: db,
                operation: operation
            )
            try step(evidenceUpsert, operation: operation, db: db)
            try reset(evidenceUpsert, operation: operation, db: db)
            try replaceStoredVocabularyTerms(
                documentNewTerms,
                episodeID: document.episodeID,
                source: metadataVocabularySource,
                operation: operation,
                db: db
            )
        }

        try insertDeletionKeys(for: newTerms, operation: operation, db: db)
        try removeOrphanedDeletionKeys(
            for: oldTerms.subtracting(newTerms),
            operation: operation,
            db: db
        )
    }

    static func replaceTranscript(
        _ document: EpisodeSearchTranscriptDocument,
        in db: OpaquePointer
    ) throws {
        let operation = "episode transcript search replace"
        let segments = document.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.startSeconds.isFinite
                && $0.endSeconds.isFinite
        }
        // Reconciliation replays every completed transcript on each launch.
        // An unchanged document (same version, same segment count) is already
        // fully indexed; skip the delete/re-insert FTS churn entirely.
        if try storedTranscriptMatches(
            document: document,
            segmentCount: segments.count,
            db: db
        ) {
            return
        }

        let oldRowIDs = try transcriptRowIDs(
            episodeIDs: [document.episodeID],
            db: db
        )
        let oldTerms = try storedVocabularyTerms(
            episodeID: document.episodeID,
            source: transcriptVocabularySource,
            db: db
        )
        try deleteFTSRows(
            rowIDs: oldRowIDs,
            table: transcriptTableName,
            operation: operation,
            db: db
        )
        try run(
            "DELETE FROM \(transcriptSegmentTableName) WHERE episode_id = ?",
            operation: operation,
            db: db
        ) { statement in
            try bind(
                document.episodeID,
                at: 1,
                statement: statement,
                db: db,
                operation: operation
            )
        }

        let contributions = EpisodeSearchSpelling.contributions(
            segments.map { ($0.text, .transcript) }
        )
        let segmentInsert = try prepare(
            """
            INSERT INTO episode_transcript_search_segment (
              segment_id, episode_id, podcast_id, transcript_version,
              start_seconds, end_seconds, text
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            operation: operation,
            db: db
        )
        defer {
            sqlite3_finalize(segmentInsert)
        }
        let searchInsert = try prepare(
            """
            INSERT INTO episode_transcript_search_fts (rowid, text)
            VALUES (?, ?)
            """,
            operation: operation,
            db: db
        )
        defer {
            sqlite3_finalize(searchInsert)
        }
        for segment in segments {
            try bind(
                segment.segmentID,
                at: 1,
                statement: segmentInsert,
                db: db,
                operation: operation
            )
            try bind(
                document.episodeID,
                at: 2,
                statement: segmentInsert,
                db: db,
                operation: operation
            )
            try bind(
                document.podcastID,
                at: 3,
                statement: segmentInsert,
                db: db,
                operation: operation
            )
            try bind(
                document.version,
                at: 4,
                statement: segmentInsert,
                db: db,
                operation: operation
            )
            try bind(
                max(0, segment.startSeconds),
                at: 5,
                statement: segmentInsert,
                db: db,
                operation: operation
            )
            try bind(
                max(segment.startSeconds, segment.endSeconds),
                at: 6,
                statement: segmentInsert,
                db: db,
                operation: operation
            )
            try bind(
                segment.text,
                at: 7,
                statement: segmentInsert,
                db: db,
                operation: operation
            )
            try step(segmentInsert, operation: operation, db: db)
            let rowID = Int(sqlite3_last_insert_rowid(db))
            try reset(segmentInsert, operation: operation, db: db)

            try bind(
                rowID,
                at: 1,
                statement: searchInsert,
                db: db,
                operation: operation
            )
            try bind(
                segment.text,
                at: 2,
                statement: searchInsert,
                db: db,
                operation: operation
            )
            try step(searchInsert, operation: operation, db: db)
            try reset(searchInsert, operation: operation, db: db)
        }
        let newTerms = Set(contributions.map(\.term))
        try replaceStoredVocabularyTerms(
            newTerms,
            episodeID: document.episodeID,
            source: transcriptVocabularySource,
            operation: operation,
            db: db
        )
        try insertDeletionKeys(for: newTerms, operation: operation, db: db)
        try removeOrphanedDeletionKeys(
            for: oldTerms.subtracting(newTerms),
            operation: operation,
            db: db
        )
    }

    static func deleteTranscript(
        episodeID: String,
        in db: OpaquePointer
    ) throws {
        let operation = "episode transcript search delete"
        let rowIDs = try transcriptRowIDs(episodeIDs: [episodeID], db: db)
        let oldTerms = try storedVocabularyTerms(
            episodeID: episodeID,
            source: transcriptVocabularySource,
            db: db
        )
        try deleteFTSRows(
            rowIDs: rowIDs,
            table: transcriptTableName,
            operation: operation,
            db: db
        )
        try run(
            "DELETE FROM \(transcriptSegmentTableName) WHERE episode_id = ?",
            operation: operation,
            db: db
        ) { statement in
            try bind(
                episodeID,
                at: 1,
                statement: statement,
                db: db,
                operation: operation
            )
        }
        try deleteStoredVocabularyTerms(
            episodeIDs: [episodeID],
            source: transcriptVocabularySource,
            operation: operation,
            db: db
        )
        try removeOrphanedDeletionKeys(
            for: oldTerms,
            operation: operation,
            db: db
        )
    }

    static func removeTranscripts(
        except episodeIDs: Set<String>,
        in db: OpaquePointer
    ) throws {
        var staleEpisodeIDs: [String] = []
        let sql: String
        if episodeIDs.isEmpty {
            sql = "SELECT DISTINCT episode_id FROM \(transcriptSegmentTableName)"
        } else {
            sql = """
            SELECT DISTINCT episode_id
            FROM \(transcriptSegmentTableName)
            WHERE episode_id NOT IN (SELECT value FROM json_each(?))
            """
        }
        try query(
            sql,
            operation: "episode transcript search reconcile",
            db: db,
            bindings: { statement in
                if !episodeIDs.isEmpty {
                    try bind(
                        jsonArray(episodeIDs),
                        at: 1,
                        statement: statement,
                        db: db,
                        operation: "episode transcript search reconcile"
                    )
                }
            }
        ) { statement in
            if let episodeID = columnText(statement, 0) {
                staleEpisodeIDs.append(episodeID)
            }
        }
        for episodeID in staleEpisodeIDs {
            try deleteTranscript(episodeID: episodeID, in: db)
        }
    }

    static func deleteEpisodes(
        episodeIDs: [String],
        in db: OpaquePointer
    ) throws {
        guard !episodeIDs.isEmpty else {
            return
        }
        let metadataRowIDs = try episodeRowIDs(
            episodeIDs: episodeIDs,
            db: db
        )
        let transcriptRowIDs = try transcriptRowIDs(
            episodeIDs: episodeIDs,
            db: db
        )
        let orphanCandidates = try storedVocabularyTerms(
            episodeIDs: episodeIDs,
            db: db
        )
        try deleteFTSRows(
            rowIDs: metadataRowIDs,
            table: tableName,
            operation: "episode search delete",
            db: db
        )
        try deleteFTSRows(
            rowIDs: transcriptRowIDs,
            table: transcriptTableName,
            operation: "episode transcript search delete",
            db: db
        )
        try run(
            """
            DELETE FROM episode_transcript_search_segment
            WHERE episode_id IN (SELECT value FROM json_each(?))
            """,
            operation: "episode transcript search delete",
            db: db
        ) { statement in
            try bind(
                jsonArray(episodeIDs),
                at: 1,
                statement: statement,
                db: db,
                operation: "episode transcript search delete"
            )
        }
        if !metadataRowIDs.isEmpty {
            try run(
                """
                DELETE FROM episode_search_evidence
                WHERE search_rowid IN (SELECT value FROM json_each(?))
                """,
                operation: "episode search evidence delete",
                db: db
            ) { statement in
                try bind(
                    jsonArray(metadataRowIDs),
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search evidence delete"
                )
            }
        }
        try deleteStoredVocabularyTerms(
            episodeIDs: episodeIDs,
            source: nil,
            operation: "episode search vocabulary delete",
            db: db
        )
        try removeOrphanedDeletionKeys(
            for: orphanCandidates,
            operation: "episode search vocabulary delete",
            db: db
        )
    }

    static func deletePodcast(
        podcastID: String,
        in db: OpaquePointer
    ) throws {
        var episodeIDs: [String] = []
        try query(
            """
            SELECT episode_id
            FROM episode_cache
            WHERE podcast_id = ?
            """,
            operation: "episode search podcast delete load",
            db: db,
            bindings: { statement in
                try bind(
                    podcastID,
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search podcast delete load"
                )
            }
        ) { statement in
            if let episodeID = columnText(statement, 0) {
                episodeIDs.append(episodeID)
            }
        }
        try deleteEpisodes(episodeIDs: episodeIDs, in: db)
    }

    static func rebuildBatch(
        after episodeID: String?,
        limit: Int,
        in db: OpaquePointer
    ) throws -> [SQLiteEpisodeSearchDocument] {
        var documents: [SQLiteEpisodeSearchDocument] = []
        let sql: String
        if episodeID == nil {
            sql = """
            SELECT episode_id, podcast_id, title, podcast_title, summary,
                   show_notes_html
            FROM episode_cache
            ORDER BY episode_id
            LIMIT ?
            """
        } else {
            sql = """
            SELECT episode_id, podcast_id, title, podcast_title, summary,
                   show_notes_html
            FROM episode_cache
            WHERE episode_id > ?
            ORDER BY episode_id
            LIMIT ?
            """
        }
        try query(
            sql,
            operation: "episode search rebuild load",
            db: db,
            bindings: { statement in
                var index: Int32 = 1
                if let episodeID {
                    try bind(
                        episodeID,
                        at: index,
                        statement: statement,
                        db: db,
                        operation: "episode search rebuild load"
                    )
                    index += 1
                }
                try bind(
                    limit,
                    at: index,
                    statement: statement,
                    db: db,
                    operation: "episode search rebuild load"
                )
            }
        ) { statement in
            documents.append(
                SQLiteEpisodeSearchDocument(
                    episodeID: columnText(statement, 0) ?? "",
                    podcastID: columnText(statement, 1) ?? "",
                    title: columnText(statement, 2) ?? "",
                    podcastTitle: columnText(statement, 3) ?? "",
                    summaryHTML: columnText(statement, 4),
                    showNotesHTML: columnText(statement, 5)
                )
            )
        }
        return documents
    }


    private static func insertDeletionKeys(
        for terms: Set<String>,
        operation: String,
        db: OpaquePointer
    ) throws {
        guard !terms.isEmpty else {
            return
        }
        var existingTerms: Set<String> = []
        try query(
            """
            SELECT DISTINCT term
            FROM episode_search_vocabulary_delete
            WHERE term IN (SELECT value FROM json_each(?))
            """,
            operation: operation,
            db: db,
            bindings: { statement in
                try bind(
                    jsonArray(terms),
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: operation
                )
            }
        ) { statement in
            if let term = columnText(statement, 0) {
                existingTerms.insert(term)
            }
        }
        let deletionKeyInsert = try prepare(
            """
            INSERT OR IGNORE INTO episode_search_vocabulary_delete (
              delete_key, term
            ) VALUES (?, ?)
            """,
            operation: operation,
            db: db
        )
        defer {
            sqlite3_finalize(deletionKeyInsert)
        }

        for term in terms.subtracting(existingTerms).sorted() {
            for deletionKey in EpisodeSearchSpelling.deletionKeys(
                for: term
            ) {
                try bind(
                    deletionKey,
                    at: 1,
                    statement: deletionKeyInsert,
                    db: db,
                    operation: operation
                )
                try bind(
                    term,
                    at: 2,
                    statement: deletionKeyInsert,
                    db: db,
                    operation: operation
                )
                try step(
                    deletionKeyInsert,
                    operation: operation,
                    db: db
                )
                try reset(
                    deletionKeyInsert,
                    operation: operation,
                    db: db
                )
            }
        }
    }

    private static func storedVocabularyTerms(
        episodeID: String,
        source: Int,
        db: OpaquePointer
    ) throws -> Set<String> {
        var terms: Set<String> = []
        try query(
            """
            SELECT terms_data
            FROM episode_search_spelling_document
            WHERE episode_id = ? AND source = ?
            LIMIT 1
            """,
            operation: "episode search spelling terms load",
            db: db,
            bindings: { statement in
                try bind(episodeID, at: 1, statement: statement, db: db,
                         operation: "episode search spelling terms load")
                try bind(source, at: 2, statement: statement, db: db,
                         operation: "episode search spelling terms load")
            }
        ) { statement in
            guard let encoded = columnData(statement, 0) else {
                return
            }
            terms.formUnion(
                try JSONDecoder().decode(
                    [String].self,
                    from: decompressedData(encoded)
                )
            )
        }
        return terms
    }

    private static func storedVocabularyTerms(
        episodeIDs: [String],
        source: Int? = nil,
        db: OpaquePointer
    ) throws -> Set<String> {
        guard !episodeIDs.isEmpty else {
            return []
        }
        let sourceSQL = source == nil ? "" : " AND source = ?"
        var terms: Set<String> = []
        try query(
            """
            SELECT terms_data
            FROM episode_search_spelling_document
            WHERE episode_id IN (SELECT value FROM json_each(?))\(sourceSQL)
            """,
            operation: "episode search spelling terms load",
            db: db,
            bindings: { statement in
                try bind(
                    jsonArray(episodeIDs),
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search spelling terms load"
                )
                if let source {
                    try bind(
                        source,
                        at: 2,
                        statement: statement,
                        db: db,
                        operation: "episode search spelling terms load"
                    )
                }
            }
        ) { statement in
            if let encoded = columnData(statement, 0) {
                terms.formUnion(
                    try JSONDecoder().decode(
                        [String].self,
                        from: decompressedData(encoded)
                    )
                )
            }
        }
        return terms
    }

    private static func replaceStoredVocabularyTerms(
        _ terms: Set<String>,
        episodeID: String,
        source: Int,
        operation: String,
        db: OpaquePointer
    ) throws {
        guard !terms.isEmpty else {
            try deleteStoredVocabularyTerms(
                episodeIDs: [episodeID],
                source: source,
                operation: operation,
                db: db
            )
            return
        }
        let encoded = try compressedData(
            JSONEncoder().encode(terms.sorted())
        )
        try run(
            """
            INSERT INTO episode_search_spelling_document (
              episode_id, source, terms_data
            ) VALUES (?, ?, ?)
            ON CONFLICT (episode_id, source) DO UPDATE SET
              terms_data = excluded.terms_data
            """,
            operation: operation,
            db: db
        ) { statement in
            try bind(episodeID, at: 1, statement: statement, db: db,
                     operation: operation)
            try bind(source, at: 2, statement: statement, db: db,
                     operation: operation)
            try bind(encoded, at: 3, statement: statement, db: db,
                     operation: operation)
        }
    }

    private static func deleteStoredVocabularyTerms(
        episodeIDs: [String],
        source: Int?,
        operation: String,
        db: OpaquePointer
    ) throws {
        guard !episodeIDs.isEmpty else {
            return
        }
        let sourceSQL = source == nil ? "" : " AND source = ?"
        try run(
            """
            DELETE FROM episode_search_spelling_document
            WHERE episode_id IN (SELECT value FROM json_each(?))\(sourceSQL)
            """,
            operation: operation,
            db: db
        ) { statement in
            try bind(jsonArray(episodeIDs), at: 1, statement: statement,
                     db: db, operation: operation)
            if let source {
                try bind(source, at: 2, statement: statement, db: db,
                         operation: operation)
            }
        }
    }

    private static func episodeRowIDsByEpisodeID(
        episodeIDs: [String],
        db: OpaquePointer
    ) throws -> [String: Int] {
        guard !episodeIDs.isEmpty else {
            return [:]
        }
        var rowIDs: [String: Int] = [:]
        try query(
            """
            SELECT episode_id, rowid
            FROM episode_cache
            WHERE episode_id IN (SELECT value FROM json_each(?))
            """,
            operation: "episode search row identifiers load",
            db: db,
            bindings: { statement in
                try bind(
                    jsonArray(episodeIDs),
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search row identifiers load"
                )
            }
        ) { statement in
            if let episodeID = columnText(statement, 0) {
                rowIDs[episodeID] = Int(sqlite3_column_int64(statement, 1))
            }
        }
        return rowIDs
    }

    private static func episodeRowIDs(
        episodeIDs: [String],
        db: OpaquePointer
    ) throws -> [Int] {
        guard !episodeIDs.isEmpty else {
            return []
        }
        var rowIDs: [Int] = []
        try query(
            """
            SELECT rowid
            FROM episode_cache
            WHERE episode_id IN (SELECT value FROM json_each(?))
            """,
            operation: "episode search row identifiers load",
            db: db,
            bindings: { statement in
                try bind(
                    jsonArray(episodeIDs),
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode search row identifiers load"
                )
            }
        ) { statement in
            rowIDs.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return rowIDs
    }

    /// Whether the stored segment rows already represent this document: one
    /// distinct `transcript_version` equal to the document's, with the same
    /// non-empty segment count.
    private static func storedTranscriptMatches(
        document: EpisodeSearchTranscriptDocument,
        segmentCount: Int,
        db: OpaquePointer
    ) throws -> Bool {
        guard segmentCount > 0 else {
            return false
        }
        var matches = false
        try query(
            """
            SELECT COUNT(*),
                   COUNT(DISTINCT transcript_version),
                   MIN(transcript_version)
            FROM \(transcriptSegmentTableName)
            WHERE episode_id = ?
            """,
            operation: "episode transcript search version load",
            db: db,
            bindings: { statement in
                try bind(
                    document.episodeID,
                    at: 1,
                    statement: statement,
                    db: db,
                    operation: "episode transcript search version load"
                )
            }
        ) { statement in
            matches = Int(sqlite3_column_int64(statement, 0)) == segmentCount
                && Int(sqlite3_column_int64(statement, 1)) == 1
                && columnText(statement, 2) == document.version
        }
        return matches
    }

    private static func transcriptRowIDs(
        episodeIDs: [String],
        db: OpaquePointer
    ) throws -> [Int] {
        guard !episodeIDs.isEmpty else {
            return []
        }
        var rowIDs: [Int] = []
        try query(
            """
            SELECT search_rowid
            FROM episode_transcript_search_segment
            WHERE episode_id IN (SELECT value FROM json_each(?))
            """,
            operation: "episode transcript search row identifiers load",
            db: db,
            bindings: { statement in
                try bind(
                    jsonArray(episodeIDs),
                    at: 1,
                    statement: statement,
                    db: db,
                    operation:
                        "episode transcript search row identifiers load"
                )
            }
        ) { statement in
            rowIDs.append(Int(sqlite3_column_int64(statement, 0)))
        }
        return rowIDs
    }

    private static func deleteFTSRows(
        rowIDs: [Int],
        table: String,
        operation: String,
        db: OpaquePointer
    ) throws {
        guard !rowIDs.isEmpty else {
            return
        }
        let delete = try prepare(
            "DELETE FROM \(table) WHERE rowid = ?",
            operation: operation,
            db: db
        )
        defer {
            sqlite3_finalize(delete)
        }
        for rowID in rowIDs {
            try bind(
                rowID,
                at: 1,
                statement: delete,
                db: db,
                operation: operation
            )
            try step(delete, operation: operation, db: db)
            try reset(delete, operation: operation, db: db)
        }
    }


    private static func removeOrphanedDeletionKeys(
        for terms: Set<String>,
        operation: String,
        db: OpaquePointer
    ) throws {
        guard !terms.isEmpty else {
            return
        }
        try run(
            """
            DELETE FROM episode_search_vocabulary_delete
            WHERE term IN (SELECT value FROM json_each(?))
              AND NOT EXISTS (
                SELECT 1
                FROM \(metadataVocabularyColumnTableName)
                WHERE \(metadataVocabularyColumnTableName).term =
                      episode_search_vocabulary_delete.term
              )
              AND NOT EXISTS (
                SELECT 1
                FROM \(transcriptVocabularyColumnTableName)
                WHERE \(transcriptVocabularyColumnTableName).term =
                      episode_search_vocabulary_delete.term
              )
            """,
            operation: operation,
            db: db
        ) { statement in
            try bind(
                jsonArray(terms),
                at: 1,
                statement: statement,
                db: db,
                operation: operation
            )
        }
    }
}
