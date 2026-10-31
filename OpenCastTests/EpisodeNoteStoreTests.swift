import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode notes")
struct EpisodeNoteStoreTests {
    @Test("Notes retain their episode and captured timestamp across store reopen")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.store")
        let schema = Schema([EpisodeNoteRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            try EpisodeNoteStore.save("  Remember this idea\n", for: draft("episode-a", at: 123.5), in: context)
            try EpisodeNoteStore.save("Other episode", for: draft("episode-b", at: 20), in: context)
            try EpisodeNoteStore.save("Earlier thought", for: draft("episode-a", at: 10), in: context)
        }
        let reopened = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(reopened)
        let episodeID = "episode-a"
        let records = try context.fetch(FetchDescriptor<EpisodeNoteRecord>(
            predicate: #Predicate { $0.episodeID == episodeID },
            sortBy: [SortDescriptor(\EpisodeNoteRecord.timestamp)]
        ))
        #expect(records.map(\.text) == ["Earlier thought", "Remember this idea"])
        #expect(records.map(\.timestamp) == [10, 123.5])
        #expect(records.allSatisfy { $0.episodeID == episodeID })
    }

    @Test("Empty notes and invalid timestamps never insert records")
    func validation() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        #expect(throws: EpisodeNoteStore.ValidationError.self) {
            try EpisodeNoteStore.save(" \n ", for: draft("episode", at: 0), in: context)
        }
        for timestamp in [-1.0, .nan, .infinity] {
            #expect(throws: EpisodeNoteStore.ValidationError.self) {
                try EpisodeNoteStore.save("A thought", for: draft("episode", at: timestamp), in: context)
            }
        }
        #expect(try context.fetchCount(FetchDescriptor<EpisodeNoteRecord>()) == 0)
    }

    @Test("Deleting one note persists and preserves other notes on the episode")
    func deletion() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let first = try EpisodeNoteStore.save("Delete me", for: draft("episode", at: 10), in: context)
        let kept = try EpisodeNoteStore.save("Keep me", for: draft("episode", at: 20), in: context)
        try EpisodeNoteStore.delete(first, in: context)
        let freshContext = ModelContext(container)
        let notes = try freshContext.fetch(FetchDescriptor<EpisodeNoteRecord>())
        #expect(notes.map(\.noteID) == [kept.noteID])
        #expect(notes.map(\.text) == ["Keep me"])
    }

    @Test("Failed deletion restores the note without discarding unrelated pending edits")
    func deletionFailure() throws {
        struct Failure: Error {}
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let note = try EpisodeNoteStore.save("Keep", for: draft("episode", at: 10), in: context)
        context.insert(LocalPreferenceRecord(key: "pending", value: "keep"))
        #expect(throws: Failure.self) {
            try EpisodeNoteStore.delete(note, in: context, save: { _ in throw Failure() })
        }
        try context.save()
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<EpisodeNoteRecord>()).map(\.text) == ["Keep"])
        #expect(try LocalPreferenceRecord.preference(forKey: "pending", modelContext: fresh)?.value == "keep")
    }

    @Test("Whole-episode saves update one note and preserve timestamped notes and other episodes")
    func wholeEpisodeNote() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        var whole = draft("episode-a", at: .nan)
        whole.isEpisodeWide = true
        let first = try EpisodeNoteStore.save("Original", for: whole, in: context)
        let moment = try EpisodeNoteStore.save("Moment", for: draft("episode-a", at: 0), in: context)
        let updated = try EpisodeNoteStore.save("  Updated  ", for: whole, in: context)
        var other = draft("episode-b", at: 0)
        other.isEpisodeWide = true
        try EpisodeNoteStore.save("Other", for: other, in: context)
        #expect(first.noteID == updated.noteID)
        let fresh = ModelContext(container)
        let notes = try fresh.fetch(FetchDescriptor<EpisodeNoteRecord>())
        #expect(notes.count == 3)
        #expect(notes.filter { $0.episodeID == "episode-a" && $0.isEpisodeWide }.map(\.text) == ["Updated"])
        #expect(notes.first { $0.noteID == moment.noteID }?.isEpisodeWide == false)
        try EpisodeNoteStore.delete(updated, in: context)
        #expect(try context.fetchCount(FetchDescriptor<EpisodeNoteRecord>()) == 2)
    }

    @Test("Editing a timestamped note preserves identity, episode and timestamp")
    func editTimestampedNote() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let original = try EpisodeNoteStore.save("Original", for: draft("episode", at: 42), in: context)
        var edit = draft("episode", at: 99)
        edit.noteID = original.noteID
        let updated = try EpisodeNoteStore.save(" Updated ", for: edit, in: context)
        #expect(updated.noteID == original.noteID)
        #expect(updated.timestamp == 42)
        #expect(!updated.isEpisodeWide)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<EpisodeNoteRecord>()).map(\.text) == ["Updated"])
        try EpisodeNoteStore.delete(updated, in: context)
        #expect(throws: EpisodeNoteStore.ValidationError.self) {
            try EpisodeNoteStore.save("Stale edit", for: edit, in: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<EpisodeNoteRecord>()) == 0)
    }

    @Test("Delete all removes both note types across episodes and preserves preferences", arguments: [false, true])
    func deleteAllNotes(fails: Bool) throws {
        struct Failure: Error {}
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        try EpisodeNoteStore.save("Moment", for: draft("a", at: 12), in: context)
        var whole = draft("b", at: 0)
        whole.isEpisodeWide = true
        try EpisodeNoteStore.save("Episode", for: whole, in: context)
        context.insert(LocalPreferenceRecord(key: "unrelated", value: "keep"))
        if fails {
            #expect(throws: Failure.self) {
                try EpisodeNoteStore.deleteAll(in: context, save: { _ in throw Failure() })
            }
            try context.save()
        } else {
            try EpisodeNoteStore.deleteAll(in: context)
        }
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<EpisodeNoteRecord>()) == (fails ? 2 : 0))
        #expect(try LocalPreferenceRecord.preference(forKey: "unrelated", modelContext: fresh)?.value == "keep")
    }

    @Test("Failed creates and edits preserve notes and unrelated pending changes", arguments: [false, true])
    func saveFailure(editing: Bool) throws {
        struct Failure: Error {}
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        var edit = draft("episode", at: 42)
        if editing {
            edit.noteID = try EpisodeNoteStore.save("Original", for: edit, in: context).noteID
        }
        context.insert(LocalPreferenceRecord(key: "pending", value: "keep"))
        #expect(throws: Failure.self) {
            try EpisodeNoteStore.save("Replacement", for: edit, in: context, save: { _ in throw Failure() })
        }
        try context.save()
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<EpisodeNoteRecord>()).map(\.text) == (editing ? ["Original"] : []))
        #expect(try LocalPreferenceRecord.preference(forKey: "pending", modelContext: fresh)?.value == "keep")
    }

    @Test("Episode identity migration preserves moments and merges whole-episode notes once")
    func identityMigration() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let moment = try EpisodeNoteStore.save("Moment", for: draft("old", at: 42), in: context)
        var old = draft("old", at: 0)
        old.isEpisodeWide = true
        let first = try EpisodeNoteStore.save("Old episode thoughts", for: old, in: context)
        first.createdAt = Date(timeIntervalSince1970: 1)
        var successor = draft("new", at: 0)
        successor.isEpisodeWide = true
        let second = try EpisodeNoteStore.save("Successor thoughts", for: successor, in: context)
        second.createdAt = Date(timeIntervalSince1970: 2)
        try EpisodeNoteStore.save("Unrelated", for: draft("other", at: 12), in: context)
        let matches = [EpisodeIdentityReconciler.Match(departedEpisodeID: "old", successorEpisodeID: "new")]
        try EpisodeIdentityMigrationApplier.apply(matches, canonicalFeedURL: "https://example.com/feed", sidecarMigrators: [], modelContext: context)
        try context.save()
        try EpisodeIdentityMigrationApplier.apply(matches, canonicalFeedURL: "https://example.com/feed", sidecarMigrators: [], modelContext: context)
        try context.save()
        let notes = try ModelContext(container).fetch(FetchDescriptor<EpisodeNoteRecord>())
        #expect(notes.count == 3)
        #expect(notes.first { $0.noteID == moment.noteID }?.episodeID == "new")
        #expect(notes.first { $0.noteID == moment.noteID }?.timestamp == 42)
        #expect(notes.filter { $0.isEpisodeWide }.map(\.text) == ["Old episode thoughts\n\nSuccessor thoughts"])
        #expect(notes.first { $0.episodeID == "other" }?.text == "Unrelated")
    }

    @Test("Adding notes to the existing local disk schema preserves preferences")
    func schemaUpgrade() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "local.store")
        let oldSchema = Schema([
            PodcastCacheRecord.self, EpisodeCacheRecord.self, RefreshLogRecord.self,
            LocalPreferenceRecord.self, EpisodeDownloadRecord.self, EpisodeTranscriptRecord.self,
            EpisodeAdAnalysisRecord.self, EpisodeTranscriptAnalysisRecord.self,
            AdFreePassQueueItemRecord.self, UpNextQueueItemRecord.self
        ])
        do {
            let configuration = ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: oldSchema, configurations: configuration)
            let context = ModelContext(container)
            context.insert(LocalPreferenceRecord(key: "existing", value: "keep"))
            try context.save()
        }
        let schema = OpenCastModelContainerFactory.localSchema
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        #expect(try LocalPreferenceRecord.preference(forKey: "existing", modelContext: context)?.value == "keep")
        try EpisodeNoteStore.save("New note", for: draft("episode", at: 12), in: context)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<EpisodeNoteRecord>()) == 1)
    }

    private func draft(_ episodeID: String, at timestamp: TimeInterval) -> EpisodeNoteDraft {
        EpisodeNoteDraft(episodeID: episodeID, episodeTitle: "Episode", timestamp: timestamp)
    }
}
