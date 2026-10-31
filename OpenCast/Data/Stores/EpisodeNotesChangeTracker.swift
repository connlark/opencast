import Observation
import SwiftData

/// Which episodes' Private Notes changed. The views that list or mark notes
/// fetch once per episode and again when `revision(for:)` moves for their
/// episode: a save, edit or delete of one of its notes, a bulk delete, or an
/// identity migration that re-keyed notes onto or off it. Nothing else
/// re-fetches, so a listener without notes pays one empty fetch per episode
/// and nothing per save.
@Observable
final class EpisodeNotesChangeTracker {
    private var revisionsByEpisodeID: [String: Int] = [:]
    private var bulkRevision = 0
    @ObservationIgnored private var stagedEpisodeIDs: Set<String> = []

    func revision(for episodeID: String) -> Int {
        bulkRevision &+ (revisionsByEpisodeID[episodeID] ?? 0)
    }

    func notesDidChange(episodeID: String) {
        revisionsByEpisodeID[episodeID, default: 0] &+= 1
    }

    func notesDidChangeEverywhere() {
        bulkRevision &+= 1
    }
}

extension EpisodeNotesChangeTracker: EpisodeIdentitySidecarMigrating {
    /// `EpisodeIdentityMigrationApplier` moves the notes themselves; this
    /// remembers the episodes a re-key touched and publishes them afterwards.
    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws {
        stagedEpisodeIDs.insert(oldEpisodeID)
        stagedEpisodeIDs.insert(newEpisodeID)
    }

    /// Publishes on both paths: a failed save leaves the re-keys pending in
    /// the shared context, where the next save commits them and a fetch
    /// already sees them, so the views follow the context either way.
    func finishEpisodeSidecarMigration(committed: Bool) {
        let staged = stagedEpisodeIDs
        stagedEpisodeIDs = []
        for episodeID in staged {
            notesDidChange(episodeID: episodeID)
        }
    }
}
