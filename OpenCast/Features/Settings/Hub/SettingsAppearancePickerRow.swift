import SwiftUI

struct SettingsAppearancePickerRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Picker(selection: modeBinding) {
            ForEach(AppAppearanceMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
            }
        } label: {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .foregroundStyle(Color.primary)
        }
        .pickerStyle(.menu)

        if let message = appModel.appearanceSettings.lastErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
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
