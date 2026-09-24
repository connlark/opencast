import SwiftUI

struct SettingsInboxView: View {
    var body: some View {
        Form {
            Section {
                SettingsInboxHidesPlayedEpisodesToggleRow()
                SettingsInboxHidesQueuedEpisodesToggleRow()
            }
        }
        .settingsSubscreen(title: "Inbox")
    }
}
