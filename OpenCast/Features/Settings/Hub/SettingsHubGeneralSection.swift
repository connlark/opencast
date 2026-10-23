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
            SettingsNavigationRow(title: "Look & Feel", systemImage: "paintpalette", route: .lookAndFeel)
        }
    }

    private var notificationsValue: String {
        appModel.notificationSettings.isEnabled ? "On" : "Off"
    }
}
