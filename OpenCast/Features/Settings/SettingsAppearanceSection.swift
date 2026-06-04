import SwiftUI

struct SettingsAppearanceSection: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Section {
            Picker("Appearance", selection: modeBinding) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if let message = appModel.appearanceSettings.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Appearance")
        }
    }

    private var modeBinding: Binding<AppAppearanceMode> {
        Binding {
            appModel.appearanceSettings.mode
        } set: { mode in
            _ = appModel.setAppearanceMode(mode, modelContext: modelContext)
        }
    }
}
