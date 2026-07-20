import Observation
import SwiftData

@Observable
final class TranscriptionEngineSettingsStore {
    static let prefersAppleSpeechPreferenceKey = "transcription.engine.prefersAppleSpeech"
    static let appleSpeechNoticeAcknowledgedPreferenceKey = "transcription.engine.appleSpeechNoticeAcknowledged"
    private static let enabledPreferenceValue = "true"
    private static let disabledPreferenceValue = "false"

    private(set) var prefersAppleSpeech = false
    private(set) var hasAcknowledgedAppleSpeechNotice = false
    private(set) var lastErrorMessage: String?

    func load(modelContext: ModelContext) {
        do {
            prefersAppleSpeech = try Self.isEnabled(
                key: Self.prefersAppleSpeechPreferenceKey,
                modelContext: modelContext
            )
            hasAcknowledgedAppleSpeechNotice = try Self.isEnabled(
                key: Self.appleSpeechNoticeAcknowledgedPreferenceKey,
                modelContext: modelContext
            )
            lastErrorMessage = nil
        } catch {
            prefersAppleSpeech = false
            hasAcknowledgedAppleSpeechNotice = false
            lastErrorMessage = "Unable to load transcription engine settings: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func setPrefersAppleSpeech(
        _ prefersAppleSpeech: Bool,
        modelContext: ModelContext
    ) -> Bool {
        let previousPreference = self.prefersAppleSpeech
        let previousAcknowledgement = hasAcknowledgedAppleSpeechNotice
        self.prefersAppleSpeech = prefersAppleSpeech
        if prefersAppleSpeech {
            hasAcknowledgedAppleSpeechNotice = true
        }

        do {
            try LocalPreferenceRecord.upsert(
                key: Self.prefersAppleSpeechPreferenceKey,
                value: prefersAppleSpeech ? Self.enabledPreferenceValue : Self.disabledPreferenceValue,
                modelContext: modelContext
            )
            if prefersAppleSpeech {
                try LocalPreferenceRecord.upsert(
                    key: Self.appleSpeechNoticeAcknowledgedPreferenceKey,
                    value: Self.enabledPreferenceValue,
                    modelContext: modelContext
                )
            }
            try modelContext.save()
            lastErrorMessage = nil
            return true
        } catch {
            self.prefersAppleSpeech = previousPreference
            hasAcknowledgedAppleSpeechNotice = previousAcknowledgement
            lastErrorMessage = "Unable to update transcription engine settings: \(error.localizedDescription)"
            return false
        }
    }

    private static func isEnabled(key: String, modelContext: ModelContext) throws -> Bool {
        try LocalPreferenceRecord.preference(forKey: key, modelContext: modelContext)?.value
            == enabledPreferenceValue
    }
}
