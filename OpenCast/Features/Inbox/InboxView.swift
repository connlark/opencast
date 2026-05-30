import SwiftData
import SwiftUI

struct InboxView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let onOpenEpisode: (String) -> Void

    var body: some View {
        List {
            if appModel.library.inboxEpisodes.isEmpty {
                ContentUnavailableView("Inbox Empty", systemImage: "tray")
            } else {
                ForEach(appModel.library.inboxEpisodes) { episode in
                    Button {
                        openEpisode(episode.episodeID)
                    } label: {
                        EpisodeRowView(episode: episode)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(EpisodeRowView.accessibilityIdentifier(for: episode.episodeID))
                }
            }
        }
        .navigationTitle("Inbox")
        .refreshable {
            await appModel.library.refreshAll(modelContext: modelContext)
        }
    }

    private func openEpisode(_ episodeID: String) {
        appModel.requestEpisodeAutoplayOnOpenIfNotListening(episodeID: episodeID)
        onOpenEpisode(episodeID)
    }
}
