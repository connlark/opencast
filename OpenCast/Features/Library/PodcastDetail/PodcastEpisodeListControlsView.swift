import SwiftUI

struct PodcastEpisodeListControlsView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    @Binding var sortOrder: PodcastEpisodeSortOrder
    @Binding var filter: PodcastEpisodeFilter
    let podcastID: String

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

                    Menu {
                        Picker("Filter Episodes", selection: $filter) {
                            ForEach(PodcastEpisodeFilter.allCases) { option in
                                Label(option.title, systemImage: option.systemImage)
                                    .tag(option)
                            }
                        }
                    } label: {
                        Label(filter.title, systemImage: filter.systemImage)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Filter Episodes, \(filter.title)")
                }
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
