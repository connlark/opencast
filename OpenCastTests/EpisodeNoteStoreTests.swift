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

    @Test("The whole-episode lookup finds only that episode's episode note")
    func wholeEpisodeLookup() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        try EpisodeNoteStore.save("Moment", for: draft("episode-a", at: 12), in: context)
        #expect(try EpisodeNoteStore.wholeEpisodeNote(for: "episode-a", in: context) == nil)
        var whole = draft("episode-a", at: 0)
        whole.isEpisodeWide = true
        let saved = try EpisodeNoteStore.save("Overall", for: whole, in: context)
        var other = draft("episode-b", at: 0)
        other.isEpisodeWide = true
        try EpisodeNoteStore.save("Other", for: other, in: context)
        let found = try EpisodeNoteStore.wholeEpisodeNote(for: "episode-a", in: ModelContext(container))
        #expect(found?.noteID == saved.noteID)
        #expect(found?.text == "Overall")
        #expect(try EpisodeNoteStore.wholeEpisodeNote(for: "episode-c", in: context) == nil)
    }

    @Test("A whole-episode draft edits the existing note, or starts a new one")
    func wholeEpisodeDraft() throws {
        let episode = snapshot("a", show: "Show", title: "Episode", artworkURL: nil)
        let fresh = EpisodeNoteDraft.wholeEpisode(episode: episode, existing: nil)
        #expect(fresh.isEpisodeWide)
        #expect(fresh.noteID == nil)
        #expect(fresh.initialText.isEmpty)
        let existing = EpisodeNoteRecord(episodeID: "a", timestamp: 0, text: "Overall")
        existing.isEpisodeWide = true
        let editing = EpisodeNoteDraft.wholeEpisode(episode: episode, existing: existing)
        #expect(editing.isEpisodeWide)
        #expect(editing.noteID == existing.noteID)
        #expect(editing.initialText == "Overall")
        #expect(editing.episodeID == "a")
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

    @Test("Episode identity migration preserves moments, merges whole-episode notes once and keeps their latest edit")
    func identityMigration() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let moment = try EpisodeNoteStore.save("Moment", for: draft("old", at: 42), in: context)
        moment.createdAt = Date(timeIntervalSince1970: 3)
        var old = draft("old", at: 0)
        old.isEpisodeWide = true
        let first = try EpisodeNoteStore.save("Old episode thoughts", for: old, in: context)
        first.createdAt = Date(timeIntervalSince1970: 1)
        var successor = draft("new", at: 0)
        successor.isEpisodeWide = true
        let second = try EpisodeNoteStore.save("Successor thoughts", for: successor, in: context)
        second.createdAt = Date(timeIntervalSince1970: 2)
        second.updatedAt = Date(timeIntervalSince1970: 500)
        let unrelated = try EpisodeNoteStore.save("Unrelated", for: draft("other", at: 12), in: context)
        unrelated.createdAt = Date(timeIntervalSince1970: 100)
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
        #expect(notes.filter { $0.episodeID == "new" }.map(\.podcastID) == ["https://example.com/feed", "https://example.com/feed"])
        #expect(notes.first { $0.episodeID == "other" }?.podcastID == "")
        let kept = try #require(notes.first { $0.isEpisodeWide })
        #expect(kept.noteID == first.noteID)
        #expect(kept.updatedAt == Date(timeIntervalSince1970: 500))
        let groups = EpisodeNotesLibraryGrouping.groups(from: notes, resolve: { _ in nil }, matching: "", sortedBy: .recent)
        #expect(groups.map(\.id) == ["new", "other"])
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

    @Test("Rail timestamps are the episode's timestamped notes only")
    func railTimestamps() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        #expect(try EpisodeNoteStore.noteTimestamps(for: "episode-a", in: context).isEmpty)
        try EpisodeNoteStore.save("Later", for: draft("episode-a", at: 90), in: context)
        try EpisodeNoteStore.save("Earlier", for: draft("episode-a", at: 15), in: context)
        try EpisodeNoteStore.save(
            "Whole",
            for: .wholeEpisode(episode: snapshot("episode-a", show: "Show", title: "A", artworkURL: nil), existing: nil),
            in: context
        )
        try EpisodeNoteStore.save("Elsewhere", for: draft("episode-b", at: 5), in: context)
        #expect(try EpisodeNoteStore.noteTimestamps(for: "episode-a", in: context).sorted() == [15, 90])
    }

    @Test("Drafts from an episode carry its show, title and artwork")
    func draftsFromEpisode() {
        let episode = snapshot("episode-a", show: "Show A", title: "Title A", artworkURL: "https://example.com/a.jpg")
        let moment = EpisodeNoteDraft.timestamped(episode: episode, timestamp: 42, resumesPlaybackOnDismiss: true)
        #expect(moment.episodeID == "episode-a")
        #expect(moment.podcastID == "feed:Show A")
        #expect(moment.podcastTitle == "Show A")
        #expect(moment.episodeTitle == "Title A")
        #expect(moment.artworkURL == "https://example.com/a.jpg")
        #expect(moment.timestamp == 42)
        #expect(!moment.isEpisodeWide)
        #expect(moment.noteID == nil)
        #expect(moment.resumesPlaybackOnDismiss)

        let fresh = EpisodeNoteDraft.wholeEpisode(episode: episode, existing: nil)
        #expect(fresh.isEpisodeWide)
        #expect(fresh.noteID == nil)
        #expect(fresh.initialText.isEmpty)
        #expect(fresh.podcastTitle == "Show A")
        #expect(fresh.episodeTitle == "Title A")

        let existing = EpisodeNoteRecord(episodeID: "episode-a", timestamp: 0, text: "Overall")
        existing.isEpisodeWide = true
        let editing = EpisodeNoteDraft.wholeEpisode(episode: episode, existing: existing)
        #expect(editing.isEpisodeWide)
        #expect(editing.noteID == existing.noteID)
        #expect(editing.initialText == "Overall")
        #expect(editing.podcastID == "feed:Show A")
        #expect(editing.artworkURL == "https://example.com/a.jpg")
        #expect(!editing.resumesPlaybackOnDismiss)
    }

    @Test("An edit draft keeps the note's stored details and fills the empty ones from the episode")
    func editDraft() {
        let note = EpisodeNoteRecord(episodeID: "episode-a", timestamp: 42, text: "Thought")
        note.podcastID = "feed:Stored Show"
        note.podcastTitle = "Stored Show"
        note.artworkURL = ""
        let live = snapshot("episode-a", show: "Live Show", title: "Live Title", artworkURL: "https://example.com/live.jpg")
        let filled = EpisodeNoteDraft.editing(note, episode: live)
        #expect(filled.episodeID == "episode-a")
        #expect(filled.noteID == note.noteID)
        #expect(filled.initialText == "Thought")
        #expect(filled.timestamp == 42)
        #expect(!filled.isEpisodeWide)
        #expect(!filled.resumesPlaybackOnDismiss)
        #expect(filled.podcastID == "feed:Stored Show")
        #expect(filled.podcastTitle == "Stored Show")
        #expect(filled.episodeTitle == "Live Title")
        #expect(filled.artworkURL == "https://example.com/live.jpg")

        note.isEpisodeWide = true
        note.episodeTitle = "Stored Title"
        note.artworkURL = "https://example.com/stored.jpg"
        let stored = EpisodeNoteDraft.editing(note, episode: live)
        #expect(stored.isEpisodeWide)
        #expect(stored.episodeTitle == "Stored Title")
        #expect(stored.artworkURL == "https://example.com/stored.jpg")

        let orphan = EpisodeNoteRecord(episodeID: "gone", timestamp: 7, text: "Orphan")
        let unresolved = EpisodeNoteDraft.editing(orphan, episode: nil)
        #expect(unresolved.episodeID == "gone")
        #expect(unresolved.noteID == orphan.noteID)
        #expect(unresolved.podcastID.isEmpty)
        #expect(unresolved.podcastTitle.isEmpty)
        #expect(unresolved.episodeTitle.isEmpty)
        #expect(unresolved.artworkURL == nil)
    }

    @Test("Note actions open drafts that carry the episode's details")
    func actionDrafts() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let episode = snapshot("episode-a", show: "Show A", title: "Title A", artworkURL: "https://example.com/a.jpg")
        let actions = EpisodeNotesActions()
        actions.addEpisodeNote(episode: episode, in: context)
        let fresh = try #require(actions.editDraft)
        #expect(fresh.isEpisodeWide)
        #expect(fresh.noteID == nil)
        #expect(fresh.podcastID == "feed:Show A")
        #expect(fresh.podcastTitle == "Show A")
        #expect(fresh.episodeTitle == "Title A")
        #expect(fresh.artworkURL == "https://example.com/a.jpg")

        let saved = try EpisodeNoteStore.save("Overall", for: fresh, in: context)
        actions.addEpisodeNote(episode: episode, in: context)
        #expect(actions.editDraft?.noteID == saved.noteID)
        #expect(actions.editDraft?.initialText == "Overall")

        actions.edit(saved, episode: nil)
        #expect(actions.editDraft?.noteID == saved.noteID)
        #expect(actions.editDraft?.episodeTitle == "Title A")
        #expect(actions.editDraft?.podcastTitle == "Show A")
        #expect(actions.openErrorMessage == nil)
    }

    @Test("Creating either note type stamps the episode's show, titles and artwork")
    func createStampsEpisodeInfo() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let episode = snapshot("episode-a", show: "Show A", title: "Title A", artworkURL: "https://example.com/a.jpg")
        try EpisodeNoteStore.save("Moment", for: .timestamped(episode: episode, timestamp: 12), in: context)
        try EpisodeNoteStore.save("Whole", for: .wholeEpisode(episode: episode, existing: nil), in: context)
        let notes = try ModelContext(container).fetch(FetchDescriptor<EpisodeNoteRecord>())
        #expect(notes.count == 2)
        for note in notes {
            #expect(note.podcastID == "feed:Show A")
            #expect(note.podcastTitle == "Show A")
            #expect(note.episodeTitle == "Title A")
            #expect(note.artworkURL == "https://example.com/a.jpg")
            #expect(note.updatedAt == nil)
        }
    }

    @Test("Editing a note sets its edit time and refreshes only the episode details the draft has")
    func editRefreshesEpisodeInfo() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let old = snapshot("episode", show: "Old Show", title: "Old Title", artworkURL: "https://example.com/old.jpg")
        let original = try EpisodeNoteStore.save("Original", for: .timestamped(episode: old, timestamp: 42), in: context)
        let createdAt = original.createdAt
        let beforeEdit = Date.now

        let partial = EpisodeNoteDraft(
            episodeID: "episode",
            episodeTitle: "New Title",
            timestamp: 42,
            noteID: original.noteID
        )
        try EpisodeNoteStore.save("Edited", for: partial, in: context)
        var stored = try #require(try ModelContext(container).fetch(FetchDescriptor<EpisodeNoteRecord>()).first)
        #expect(stored.text == "Edited")
        #expect(stored.episodeTitle == "New Title")
        #expect(stored.podcastTitle == "Old Show")
        #expect(stored.podcastID == "feed:Old Show")
        #expect(stored.artworkURL == "https://example.com/old.jpg")
        #expect(stored.createdAt == createdAt)
        let firstEdit = try #require(stored.updatedAt)
        #expect(firstEdit >= beforeEdit)

        var full = EpisodeNoteDraft.timestamped(
            episode: snapshot("episode", show: "New Show", title: "Newer Title", artworkURL: "https://example.com/new.jpg"),
            timestamp: 42
        )
        full.noteID = original.noteID
        try EpisodeNoteStore.save("Edited again", for: full, in: context)
        stored = try #require(try ModelContext(container).fetch(FetchDescriptor<EpisodeNoteRecord>()).first)
        #expect(stored.episodeTitle == "Newer Title")
        #expect(stored.podcastTitle == "New Show")
        #expect(stored.podcastID == "feed:New Show")
        #expect(stored.artworkURL == "https://example.com/new.jpg")
        let secondEdit = try #require(stored.updatedAt)
        #expect(secondEdit >= firstEdit)

        let blank = EpisodeNoteDraft(
            episodeID: "episode",
            episodeTitle: "",
            artworkURL: "",
            timestamp: 42,
            noteID: original.noteID
        )
        try EpisodeNoteStore.save("Edited once more", for: blank, in: context)
        stored = try #require(try ModelContext(container).fetch(FetchDescriptor<EpisodeNoteRecord>()).first)
        #expect(stored.text == "Edited once more")
        #expect(stored.episodeTitle == "Newer Title")
        #expect(stored.podcastTitle == "New Show")
        #expect(stored.podcastID == "feed:New Show")
        #expect(stored.artworkURL == "https://example.com/new.jpg")
        let thirdEdit = try #require(stored.updatedAt)
        #expect(thirdEdit >= secondEdit)
    }

    @Test("A failed edit restores the note's text, episode details and edit time")
    func failedEditRestoresEpisodeInfo() throws {
        struct Failure: Error {}
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let old = snapshot("episode", show: "Old Show", title: "Old Title", artworkURL: "https://example.com/old.jpg")
        let note = try EpisodeNoteStore.save("Original", for: .timestamped(episode: old, timestamp: 42), in: context)
        var edit = EpisodeNoteDraft.timestamped(
            episode: snapshot("episode", show: "New Show", title: "New Title", artworkURL: "https://example.com/new.jpg"),
            timestamp: 42
        )
        edit.noteID = note.noteID
        #expect(throws: Failure.self) {
            try EpisodeNoteStore.save("Replacement", for: edit, in: context, save: { _ in throw Failure() })
        }
        #expect(note.text == "Original")
        #expect(note.podcastID == "feed:Old Show")
        #expect(note.podcastTitle == "Old Show")
        #expect(note.episodeTitle == "Old Title")
        #expect(note.artworkURL == "https://example.com/old.jpg")
        #expect(note.updatedAt == nil)
        try context.save()
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<EpisodeNoteRecord>()).first)
        #expect(stored.text == "Original")
        #expect(stored.episodeTitle == "Old Title")
        #expect(stored.updatedAt == nil)

        let editedAt = Date(timeIntervalSince1970: 1_000)
        note.updatedAt = editedAt
        try context.save()
        #expect(throws: Failure.self) {
            try EpisodeNoteStore.save("Second replacement", for: edit, in: context, save: { _ in throw Failure() })
        }
        #expect(note.text == "Original")
        #expect(note.updatedAt == editedAt)
        try context.save()
        let restored = try #require(try ModelContext(container).fetch(FetchDescriptor<EpisodeNoteRecord>()).first)
        #expect(restored.text == "Original")
        #expect(restored.podcastTitle == "Old Show")
        #expect(restored.episodeTitle == "Old Title")
        #expect(restored.artworkURL == "https://example.com/old.jpg")
        #expect(restored.updatedAt == editedAt)
    }

    @Test("All notes spans every episode newest first, and the count covers both note types")
    func allNotesAndCount() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        #expect(try EpisodeNoteStore.noteCount(in: context) == 0)
        #expect(try context.fetch(EpisodeNoteStore.allNotes()).isEmpty)
        let a = try EpisodeNoteStore.save("A", for: draft("episode-a", at: 10), in: context)
        a.createdAt = Date(timeIntervalSince1970: 1)
        var whole = draft("episode-b", at: 0)
        whole.isEpisodeWide = true
        let b = try EpisodeNoteStore.save("B", for: whole, in: context)
        b.createdAt = Date(timeIntervalSince1970: 3)
        let c = try EpisodeNoteStore.save("C", for: draft("episode-c", at: 5), in: context)
        c.createdAt = Date(timeIntervalSince1970: 2)
        try context.save()
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(EpisodeNoteStore.allNotes()).map(\.text) == ["B", "C", "A"])
        #expect(try EpisodeNoteStore.noteCount(in: fresh) == 3)
    }

    @Test("Backfill fills only missing details of notes whose episode resolves, in one save", arguments: [false, true])
    func backfill(fails: Bool) throws {
        struct Failure: Error {}
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let legacy = EpisodeNoteRecord(episodeID: "known", timestamp: 10, text: "Legacy")
        let partial = EpisodeNoteRecord(episodeID: "known", timestamp: 20, text: "Partial")
        partial.episodeTitle = "Kept Title"
        partial.artworkURL = "https://example.com/kept.jpg"
        let orphan = EpisodeNoteRecord(episodeID: "gone", timestamp: 30, text: "Orphan")
        for note in [legacy, partial, orphan] { context.insert(note) }
        try context.save()
        context.insert(LocalPreferenceRecord(key: "pending", value: "keep"))
        let live = snapshot("known", show: "Live Show", title: "Live Title", artworkURL: "https://example.com/live.jpg")
        let notes = try context.fetch(EpisodeNoteStore.allNotes())

        var saves = 0
        var thrown: (any Error)?
        do {
            try EpisodeNoteStore.backfillEpisodeInfo(notes, resolve: { $0 == "known" ? live : nil }, in: context) { context in
                saves += 1
                if fails { throw Failure() }
                try context.save()
            }
        } catch {
            thrown = error
        }
        #expect((thrown is Failure) == fails)
        #expect(saves == 1)

        if fails {
            #expect(legacy.podcastID.isEmpty)
            #expect(legacy.podcastTitle.isEmpty)
            #expect(legacy.episodeTitle.isEmpty)
            #expect(legacy.artworkURL == nil)
            #expect(partial.podcastTitle.isEmpty)
            #expect(partial.episodeTitle == "Kept Title")
        }
        try context.save()
        let fresh = ModelContext(container)
        let stored = try fresh.fetch(FetchDescriptor<EpisodeNoteRecord>())
        let storedLegacy = try #require(stored.first { $0.noteID == legacy.noteID })
        let storedPartial = try #require(stored.first { $0.noteID == partial.noteID })
        let storedOrphan = try #require(stored.first { $0.noteID == orphan.noteID })
        #expect(storedLegacy.podcastID == (fails ? "" : "feed:Live Show"))
        #expect(storedLegacy.podcastTitle == (fails ? "" : "Live Show"))
        #expect(storedLegacy.episodeTitle == (fails ? "" : "Live Title"))
        #expect(storedLegacy.artworkURL == (fails ? nil : "https://example.com/live.jpg"))
        #expect(storedPartial.podcastID == (fails ? "" : "feed:Live Show"))
        #expect(storedPartial.podcastTitle == (fails ? "" : "Live Show"))
        #expect(storedPartial.episodeTitle == "Kept Title")
        #expect(storedPartial.artworkURL == "https://example.com/kept.jpg")
        #expect(storedOrphan.podcastID.isEmpty)
        #expect(storedOrphan.podcastTitle.isEmpty)
        #expect(storedOrphan.episodeTitle.isEmpty)
        #expect(storedOrphan.artworkURL == nil)
        #expect(stored.allSatisfy { $0.updatedAt == nil })
        #expect(try LocalPreferenceRecord.preference(forKey: "pending", modelContext: fresh)?.value == "keep")
    }

    @Test("Backfill never overwrites stored details and saves nothing when nothing is missing or nothing can be filled")
    func backfillWithoutChanges() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let stamped = snapshot("known", show: "Stored Show", title: "Stored Title", artworkURL: "https://example.com/stored.jpg")
        let note = try EpisodeNoteStore.save("Stamped", for: .timestamped(episode: stamped, timestamp: 5), in: context)
        context.insert(EpisodeNoteRecord(episodeID: "gone", timestamp: 30, text: "Orphan"))
        let bare = EpisodeNoteRecord(episodeID: "bare", timestamp: 8, text: "Bare")
        bare.podcastID = "feed:bare"
        context.insert(bare)
        try context.save()
        let episodes = [
            "known": snapshot("known", show: "Live Show", title: "Live Title", artworkURL: "https://example.com/live.jpg"),
            "bare": snapshot("bare", show: "", title: "", artworkURL: ""),
        ]
        var saves = 0
        try EpisodeNoteStore.backfillEpisodeInfo(
            try context.fetch(EpisodeNoteStore.allNotes()),
            resolve: { episodes[$0] },
            in: context
        ) { _ in saves += 1 }
        #expect(saves == 0)
        #expect(note.podcastID == "feed:Stored Show")
        #expect(note.podcastTitle == "Stored Show")
        #expect(note.episodeTitle == "Stored Title")
        #expect(note.artworkURL == "https://example.com/stored.jpg")
        #expect(bare.podcastID == "feed:bare")
        #expect(bare.podcastTitle.isEmpty)
        #expect(bare.episodeTitle.isEmpty)
        #expect(bare.artworkURL == nil)
    }

    private func draft(_ episodeID: String, at timestamp: TimeInterval) -> EpisodeNoteDraft {
        EpisodeNoteDraft(episodeID: episodeID, episodeTitle: "Episode", timestamp: timestamp)
    }

    private func snapshot(_ episodeID: String, show: String, title: String, artworkURL: String?) -> EpisodeListItemSnapshot {
        EpisodeListItemSnapshot(
            episodeID: episodeID,
            podcastID: "feed:\(show)",
            podcastTitle: show,
            title: title,
            summary: nil,
            publishedAt: nil,
            duration: nil,
            audioURL: nil,
            artworkURL: artworkURL,
            artworkPreview: nil,
            guid: nil,
            cachedAt: .now
        )
    }
}
