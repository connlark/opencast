import SwiftUI

struct SettingsLookAndFeelView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Form {
            Section {
                SettingsAppearancePickerRow()
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
