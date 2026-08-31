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
}

extension DownloadStore: EpisodeIdentitySidecarMigrating {}
extension EpisodeTranscriptionStore: EpisodeIdentitySidecarMigrating {}
extension EpisodeAdAnalysisStore: EpisodeIdentitySidecarMigrating {}
extension EpisodeTranscriptAnalysisStore: EpisodeIdentitySidecarMigrating {}
