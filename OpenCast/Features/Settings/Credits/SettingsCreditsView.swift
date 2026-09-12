import SwiftUI

struct SettingsCreditsView: View {
    var body: some View {
        Form {
            SettingsRemoteTranscriptionSection()
        }
        .settingsSubscreen(title: "Transcription Credits")
    }
}
