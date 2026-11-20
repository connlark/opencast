import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Transcription engine settings store")
struct TranscriptionEngineSettingsStoreTests {
    @Test("Enabling Apple Speech persists the preference and warning acknowledgement")
    func enablingPersistsPreferenceAndAcknowledgement() throws {
        let context = try makeContext()
        let store = TranscriptionEngineSettingsStore()

        #expect(store.setPrefersAppleSpeech(true, modelContext: context))

        let reloadedStore = TranscriptionEngineSettingsStore()
        reloadedStore.load(modelContext: context)
        #expect(reloadedStore.prefersAppleSpeech)
        #expect(reloadedStore.hasAcknowledgedAppleSpeechNotice)
        #expect(try LocalPreferenceRecord.preference(
            forKey: TranscriptionEngineSettingsStore.prefersAppleSpeechPreferenceKey,
            modelContext: context
        )?.value == "true")
        #expect(try LocalPreferenceRecord.preference(
            forKey: TranscriptionEngineSettingsStore.appleSpeechNoticeAcknowledgedPreferenceKey,
            modelContext: context
        )?.value == "true")
    }

    @Test("Disabling Apple Speech preserves the warning acknowledgement")
    func disablingPreservesAcknowledgement() throws {
        let context = try makeContext()
        let store = TranscriptionEngineSettingsStore()
        #expect(store.setPrefersAppleSpeech(true, modelContext: context))

        #expect(store.setPrefersAppleSpeech(false, modelContext: context))

        let reloadedStore = TranscriptionEngineSettingsStore()
        reloadedStore.load(modelContext: context)
        #expect(!reloadedStore.prefersAppleSpeech)
        #expect(reloadedStore.hasAcknowledgedAppleSpeechNotice)
    }

    private func makeContext() throws -> ModelContext {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        return ModelContext(container)
    }
}
