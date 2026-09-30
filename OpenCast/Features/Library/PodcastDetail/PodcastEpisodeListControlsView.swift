import SwiftUI

struct PodcastEpisodeListControlsView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var sortOrder: PodcastEpisodeSortOrder
    @Binding var filter: PodcastEpisodeFilter
    let podcastID: String
    /// Set while a Group by Podcast visit hides Up Next; the filter chip
    /// cannot show it, so a caption says why rows are missing.
    var hidesQueuedEpisodes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Menu {
                        Picker("Sort Episodes", selection: $sortOrder) {
                            ForEach(PodcastEpisodeSortOrder.allCases) { option in
                                Text(option.title)
                                    .tag(option)
                            }
                        }
                    } label: {
                        Label(sortOrder.title, systemImage: "arrow.up.arrow.down")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Sort Episodes, \(sortOrder.title)")

                    EpisodeFilterMenu(filter: $filter)
                }
            }

            if hidesQueuedEpisodes {
                Label("Episodes in Up Next are hidden", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let errorMessage = appModel.podcastEpisodeListSettings.errorMessage(forPodcastID: podcastID) {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }
}
