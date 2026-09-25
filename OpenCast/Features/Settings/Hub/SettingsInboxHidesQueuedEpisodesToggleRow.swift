import SwiftData
import SwiftUI

struct SettingsInboxHidesQueuedEpisodesToggleRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Toggle(isOn: hidesQueuedEpisodesBinding) {
            Text("Hide Queued Episodes")
        }

        if let message = appModel.inboxSettings.lastErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var hidesQueuedEpisodesBinding: Binding<Bool> {
        Binding {
            appModel.inboxSettings.hidesQueuedEpisodes
        } set: { hidesQueuedEpisodes in
            appModel.inboxSettings.setHidesQueuedEpisodes(hidesQueuedEpisodes, modelContext: modelContext)
        }
    }
}
