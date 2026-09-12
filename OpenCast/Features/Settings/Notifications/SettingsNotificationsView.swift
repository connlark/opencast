import SwiftUI

struct SettingsNotificationsView: View {
    var body: some View {
        Form {
            SettingsNotificationsSection()
        }
        .settingsSubscreen(title: "Notifications")
    }
}
