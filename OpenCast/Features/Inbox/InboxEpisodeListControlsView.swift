import SwiftUI

struct InboxEpisodeListControlsView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var filter: PodcastEpisodeFilter
    @Binding var hidesQueuedEpisodes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EpisodeFilterMenu(filter: $filter) {
                Divider()
                Toggle(isOn: $hidesQueuedEpisodes) {
                    Label("Hide Up Next Episodes", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)

            if let errorMessage = appModel.inboxEpisodeListSettings.lastErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }
}
