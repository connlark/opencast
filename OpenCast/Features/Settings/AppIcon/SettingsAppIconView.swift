import SwiftUI

struct SettingsAppIconView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        List {
            Section {
                ForEach(AppIconOption.allCases) { option in
                    AppIconOptionRow(option: option)
                }

                if let message = appModel.appIcon.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                if !appModel.appIcon.isSupported {
                    Text("This device doesn't support changing the app icon.")
                }
            }
        }
        .settingsSubscreen(title: "App Icon")
        .task(appModel.appIcon.load)
    }
}
