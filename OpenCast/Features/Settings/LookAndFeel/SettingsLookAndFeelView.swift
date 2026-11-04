import SwiftUI

struct SettingsLookAndFeelView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.activeTabBarPlacement) private var activeTabBarPlacement

    var body: some View {
        Form {
            Section {
                SettingsAppearancePickerRow()
                SettingsNavigationRow(
                    title: "App Icon",
                    systemImage: "app",
                    route: .appIcon,
                    value: appModel.appIcon.selection.title
                )
            }

            Section {
                SettingsNewEpisodeBadgesToggleRow()
                // Offered only where a bottom tab bar is the bar in this
                // context; the stored preference is kept either way.
                if activeTabBarPlacement?.minimizesOnScroll == true {
                    SettingsTabBarMinimizeToggleRow()
                }
            }
        }
        .settingsSubscreen(title: "Look & Feel")
    }
}
