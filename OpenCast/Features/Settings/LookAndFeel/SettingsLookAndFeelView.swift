import SwiftUI

struct SettingsLookAndFeelView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
                // Only the compact tab bar can minimize.
                if horizontalSizeClass == .compact {
                    SettingsTabBarMinimizeToggleRow()
                }
            }
        }
        .settingsSubscreen(title: "Look & Feel")
    }
}
