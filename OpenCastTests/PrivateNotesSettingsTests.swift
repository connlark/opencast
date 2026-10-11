import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Private Notes settings")
struct PrivateNotesSettingsTests {
    @Test("Note buttons default off and enabling them survives a fresh settings store")
    func persistence() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = PlaybackSettingsStore()
        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())
        #expect(!store.showsPrivateNoteButtons)
        #expect(store.setPrivateNoteButtonsEnabled(true, modelContext: context))
        let fresh = PlaybackSettingsStore()
        fresh.load(modelContext: ModelContext(container), playback: PlaybackVoiceBoostControllerSpy())
        #expect(fresh.showsPrivateNoteButtons)
        #expect(store.setPrivateNoteButtonsEnabled(false, modelContext: context))
        fresh.load(modelContext: ModelContext(container), playback: PlaybackVoiceBoostControllerSpy())
        #expect(!fresh.showsPrivateNoteButtons)
    }

    @Test("Failed setting saves preserve the prior value and unrelated pending changes", arguments: [nil, "true", "false"] as [String?])
    func saveFailure(value: String?) throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        if let value {
            context.insert(LocalPreferenceRecord(key: PlaybackSettingsStore.privateNoteButtonsPreferenceKey, value: value))
            try context.save()
        }
        let pending = LocalPreferenceRecord(key: "pending", value: "keep")
        context.insert(pending)
        let store = PlaybackSettingsStore(save: { _ in throw Failure() })
        store.load(modelContext: context, playback: PlaybackVoiceBoostControllerSpy())
        let prior = store.showsPrivateNoteButtons
        #expect(!store.setPrivateNoteButtonsEnabled(!prior, modelContext: context))
        #expect(store.showsPrivateNoteButtons == prior)
        #expect(store.lastErrorMessage != nil)
        try context.save()
        let fresh = ModelContext(container)
        #expect(try LocalPreferenceRecord.preference(forKey: "pending", modelContext: fresh)?.value == "keep")
        #expect(try LocalPreferenceRecord.preference(forKey: PlaybackSettingsStore.privateNoteButtonsPreferenceKey, modelContext: fresh)?.value == value)
    }

    private struct Failure: Error {}
}
