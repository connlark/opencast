import SwiftData
import SwiftUI

struct SettingsInboxHidesPlayedEpisodesToggleRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Toggle(isOn: showsUnplayedOnlyBinding) {
            Text("Hide Played Episodes")
        }

        if let message = appModel.inboxSettings.lastErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var showsUnplayedOnlyBinding: Binding<Bool> {
        Binding {
            appModel.inboxSettings.hidesPlayedEpisodes
        } set: { showsUnplayedOnly in
            appModel.inboxSettings.setShowsUnplayedOnly(showsUnplayedOnly, modelContext: modelContext)
        }
    }
}
