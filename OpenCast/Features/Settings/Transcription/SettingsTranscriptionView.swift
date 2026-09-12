import SwiftUI

struct SettingsTranscriptionView: View {
    var body: some View {
        Form {
            SettingsTranscriptionEngineSection()
            SettingsWhisperModelSection()
            SettingsAppleSpeechSection()
        }
        .settingsSubscreen(title: "Transcription")
    }
}
