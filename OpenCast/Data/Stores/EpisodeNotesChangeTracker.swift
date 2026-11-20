import Observation
import SwiftData

@Observable
final class EpisodeNotesChangeTracker {
    private(set) var allNotesRevision = 0
    private var revisionsByEpisodeID: [String: Int] = [:]
    private var bulkRevision = 0
    @ObservationIgnored private var stagedEpisodeIDs: Set<String> = []

    func revision(for episodeID: String) -> Int {
        bulkRevision &+ (revisionsByEpisodeID[episodeID] ?? 0)
    }

    func notesDidChange(episodeID: String) {
        revisionsByEpisodeID[episodeID, default: 0] &+= 1
        allNotesRevision &+= 1
    }

    func notesDidChangeEverywhere() {
        bulkRevision &+= 1
        allNotesRevision &+= 1
    }
}

extension EpisodeNotesChangeTracker: EpisodeIdentitySidecarMigrating {
    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws {
        stagedEpisodeIDs.insert(oldEpisodeID)
        stagedEpisodeIDs.insert(newEpisodeID)
    }

    /// Publishes even when not committed: a failed save leaves the re-keys pending in the
    /// shared context, where a fetch already sees them.
    func finishEpisodeSidecarMigration(committed: Bool) {
        let staged = stagedEpisodeIDs
        stagedEpisodeIDs = []
        for episodeID in staged {
            notesDidChange(episodeID: episodeID)
        }
    }
}
