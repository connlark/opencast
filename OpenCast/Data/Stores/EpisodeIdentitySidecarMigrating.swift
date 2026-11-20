import SwiftData

/// Mutate records in the given context without saving; the reconciliation owns the one save.
/// The successor ID may already own records: never overwrite a valid successor artifact with
/// an old-identity file, and never leave two active records for one episode ID.
protocol EpisodeIdentitySidecarMigrating: AnyObject {
    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws

    /// Runs once per subscription migration, after every episode re-key and before the save.
    func migrateFeedSidecars(
        from oldCanonicalFeedURL: String,
        to newCanonicalFeedURL: String,
        modelContext: ModelContext
    ) throws

    /// Runs once after the save on every path; `committed` is false when the migration or save
    /// threw. A store that mirrors rows into value copies publishes what it staged only on commit.
    func finishEpisodeSidecarMigration(committed: Bool)
}

extension EpisodeIdentitySidecarMigrating {
    func migrateFeedSidecars(
        from oldCanonicalFeedURL: String,
        to newCanonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {}

    func finishEpisodeSidecarMigration(committed: Bool) {}
}

extension DownloadStore: EpisodeIdentitySidecarMigrating {}
extension EpisodeTranscriptionStore: EpisodeIdentitySidecarMigrating {}
extension EpisodeAdAnalysisStore: EpisodeIdentitySidecarMigrating {}
extension EpisodeTranscriptAnalysisStore: EpisodeIdentitySidecarMigrating {}
