import SwiftUI

struct SettingsHubGeneralSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        Section {
            SettingsNavigationRow(title: "Playback", systemImage: "play.circle", route: .playback)
            SettingsNavigationRow(
                title: "Notifications",
                systemImage: "bell",
                route: .notifications,
                value: notificationsValue
            )
            SettingsAppearancePickerRow()
            SettingsNewEpisodeBadgesToggleRow()
            SettingsNavigationRow(
                title: "App Icon",
                systemImage: "app",
                route: .appIcon,
                value: appModel.appIcon.selection.qualifiedTitle
            )
        }
    }

    private var notificationsValue: String {
        appModel.notificationSettings.isEnabled ? "On" : "Off"
    }
}
