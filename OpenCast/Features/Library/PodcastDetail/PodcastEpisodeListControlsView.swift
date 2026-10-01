import SwiftUI

struct PodcastEpisodeListControlsView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var sortOrder: PodcastEpisodeSortOrder
    @Binding var filter: PodcastEpisodeFilter
    let podcastID: String
    /// Set while a Group by Podcast visit hides Up Next. The filter chip
    /// cannot show that, so a caption says why rows are missing and brings
    /// them back.
    var onShowHiddenEpisodes: (() -> Void)?

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

            if let onShowHiddenEpisodes {
                Button(action: onShowHiddenEpisodes) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(
                            "Episodes playing or in Up Next are hidden",
                            systemImage: "text.line.first.and.arrowtriangle.forward"
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        Spacer(minLength: 0)
                        Text("Show")
                            .foregroundStyle(.tint)
                    }
                    .font(.caption)
                    // A caption line alone is too short a target.
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
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
