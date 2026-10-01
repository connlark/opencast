import SwiftData

/// Stores that key device-local records and files on episode ID adopt this so
/// identity reconciliation can carry their data when an episode re-keys.
/// Implementations mutate records in the given context without saving —
/// the reconciliation owns the single save that commits the whole migration.
///
/// Migration is collision-aware: the successor episode ID may already own
/// records and artifacts (the old and new feed identities were both used on
/// this device). Implementations must resolve that deliberately — never
/// overwrite a valid successor artifact with an old-identity file, and never
/// leave two active records for one episode ID. `canonicalPodcastID` is the
/// successor's canonical feed URL; surviving migrated rows adopt it.
protocol EpisodeIdentitySidecarMigrating: AnyObject {
    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws

    /// Called once per subscription migration, after every episode re-key
    /// and before the save, for records keyed on the feed itself rather than
    /// on an episode (a smart playlist rule's shows). Same contract as the
    /// episode hook: mutate, never save.
    func migrateFeedSidecars(
        from oldCanonicalFeedURL: String,
        to newCanonicalFeedURL: String,
        modelContext: ModelContext
    ) throws

    /// Called once after the reconciliation's save on every path:
    /// `committed` is false when the migration or its save threw and the
    /// context still holds the re-keys as unsaved changes. Stores whose
    /// memory is the `@Model` rows need nothing; a store that mirrors rows
    /// into value copies publishes what it staged only on commit and drops
    /// it otherwise, so memory never runs ahead of storage.
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
