import SwiftData
import SwiftUI

/// Save errors show under the Appearance row, which shares this store.
struct SettingsTabBarMinimizeToggleRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Toggle(isOn: minimizesTabBarBinding) {
            Label {
                Text("Minimize Tab Bar on Scroll")
            } icon: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .foregroundStyle(Color.primary)
            }
        }
    }

    private var minimizesTabBarBinding: Binding<Bool> {
        Binding {
            appModel.appearanceSettings.minimizesTabBarOnScroll
        } set: { minimizesTabBar in
            appModel.appearanceSettings.setMinimizesTabBarOnScroll(minimizesTabBar, modelContext: modelContext)
        }
    }
}
