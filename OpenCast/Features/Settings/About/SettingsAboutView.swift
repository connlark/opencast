import SwiftUI

struct SettingsAboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(OpenCastAppVersion.displayText)
                } label: {
                    Label("Version", systemImage: "info.circle")
                }
            }

            SettingsSiriSection()
        }
        .settingsSubscreen(title: "About")
    }
}
