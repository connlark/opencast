import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode notes change tracker")
struct EpisodeNotesChangeTrackerTests {
    @Test("A note change moves only its episode's revision; a bulk delete moves every episode's")
    func scopedRevisions() {
        let tracker = EpisodeNotesChangeTracker()
        let a = tracker.revision(for: "a")
        let b = tracker.revision(for: "b")
        tracker.notesDidChange(episodeID: "a")
        #expect(tracker.revision(for: "a") != a)
        #expect(tracker.revision(for: "b") == b)
        let movedA = tracker.revision(for: "a")
        tracker.notesDidChangeEverywhere()
        #expect(tracker.revision(for: "a") != movedA)
        #expect(tracker.revision(for: "b") != b)
    }

    @Test("The all-notes revision moves on a per-episode change and on a bulk change")
    func allNotesRevision() {
        let tracker = EpisodeNotesChangeTracker()
        let start = tracker.allNotesRevision
        let b = tracker.revision(for: "b")
        tracker.notesDidChange(episodeID: "a")
        let afterEpisode = tracker.allNotesRevision
        #expect(afterEpisode != start)
        #expect(tracker.revision(for: "b") == b)
        tracker.notesDidChangeEverywhere()
        #expect(tracker.allNotesRevision != afterEpisode)
    }

    @Test("An identity migration publishes the re-keyed episodes whether or not its save landed")
    func identityMigration() throws {
        let tracker = EpisodeNotesChangeTracker()
        let context = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
        try EpisodeNoteStore.save("Moved", for: EpisodeNoteDraft(episodeID: "old", episodeTitle: "Episode", timestamp: 30), in: context)
        let old = tracker.revision(for: "old")
        let new = tracker.revision(for: "new")
        let all = tracker.allNotesRevision
        try EpisodeIdentityMigrationApplier.apply(
            [EpisodeIdentityReconciler.Match(departedEpisodeID: "old", successorEpisodeID: "new")],
            canonicalFeedURL: "https://example.com/feed",
            sidecarMigrators: [tracker],
            modelContext: context
        )
        // How the coordinator reports a failed save: the re-keys stay pending
        // in the context for the next save, so the views must re-fetch anyway.
        tracker.finishEpisodeSidecarMigration(committed: false)
        #expect(tracker.revision(for: "old") != old)
        #expect(tracker.revision(for: "new") != new)
        #expect(tracker.allNotesRevision != all)
        #expect(tracker.revision(for: "other") == 0)
        #expect(try EpisodeNoteStore.noteTimestamps(for: "old", in: context).isEmpty)
        #expect(try EpisodeNoteStore.noteTimestamps(for: "new", in: context) == [30])

        let movedNew = tracker.revision(for: "new")
        try EpisodeIdentityMigrationApplier.apply(
            [EpisodeIdentityReconciler.Match(departedEpisodeID: "new", successorEpisodeID: "newer")],
            canonicalFeedURL: "https://example.com/feed",
            sidecarMigrators: [tracker],
            modelContext: context
        )
        tracker.finishEpisodeSidecarMigration(committed: true)
        #expect(tracker.revision(for: "new") != movedNew)
        #expect(tracker.revision(for: "newer") != 0)
        #expect(try EpisodeNoteStore.noteTimestamps(for: "newer", in: context) == [30])
    }

    @Test("A migrator failing after the note re-key still publishes the episodes")
    func migratorFailureAfterRekey() throws {
        let tracker = EpisodeNotesChangeTracker()
        let context = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
        try EpisodeNoteStore.save("Moved", for: EpisodeNoteDraft(episodeID: "old", episodeTitle: "Episode", timestamp: 30), in: context)
        // The app registers the tracker first for exactly this case.
        #expect(throws: FailingSidecarMigrator.Failure.self) {
            try EpisodeIdentityMigrationApplier.apply(
                [EpisodeIdentityReconciler.Match(departedEpisodeID: "old", successorEpisodeID: "new")],
                canonicalFeedURL: "https://example.com/feed",
                sidecarMigrators: [tracker, FailingSidecarMigrator()],
                modelContext: context
            )
        }
        tracker.finishEpisodeSidecarMigration(committed: false)
        #expect(tracker.revision(for: "old") != 0)
        #expect(tracker.revision(for: "new") != 0)
        #expect(try EpisodeNoteStore.noteTimestamps(for: "new", in: context) == [30])
    }
}

@MainActor
private final class FailingSidecarMigrator: EpisodeIdentitySidecarMigrating {
    struct Failure: Error {}

    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws {
        throw Failure()
    }
}
