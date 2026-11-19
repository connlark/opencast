import SwiftData
import SwiftUI

/// Save errors show under the Appearance row, which shares this store.
struct SettingsUpNextTabToggleRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Toggle(isOn: showsUpNextTabBinding) {
            Label {
                Text("Up Next Tab")
            } icon: {
                Image(systemName: AppSection.upNext.systemImage)
                    .foregroundStyle(Color.primary)
            }
        }
    }

    private var showsUpNextTabBinding: Binding<Bool> {
        Binding {
            appModel.appearanceSettings.showsUpNextTab
        } set: { showsUpNextTab in
            appModel.appearanceSettings.setShowsUpNextTab(showsUpNextTab, modelContext: modelContext)
        }
    }
}
