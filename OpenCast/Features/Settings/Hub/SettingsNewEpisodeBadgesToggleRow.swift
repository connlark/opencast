import SwiftData
import SwiftUI

struct SettingsNewEpisodeBadgesToggleRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Toggle(isOn: showsBadgesBinding) {
            Label {
                Text("New Episode Badges")
                Text("Unfinished episodes from the past 30 days, released since you followed each show.")
            } icon: {
                Image(systemName: "app.badge")
                    .foregroundStyle(Color.primary)
            }
        }

        if let message = appModel.libraryDisplaySettings.lastErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var showsBadgesBinding: Binding<Bool> {
        Binding {
            appModel.libraryDisplaySettings.showsNewEpisodeBadges
        } set: { showsBadges in
            appModel.libraryDisplaySettings.setShowsNewEpisodeBadges(showsBadges, modelContext: modelContext)
        }
    }
}
