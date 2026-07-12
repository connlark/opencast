import SwiftUI

struct DownloadSelectionRowView: View {
    let item: DownloadListItem
    var searchResult: EpisodeSearchResult?

    static func accessibilityIdentifier(for episodeID: String) -> String {
        "download-selection-row-\(episodeID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EpisodeRowView(episode: item.episode, searchResult: searchResult)
            if item.isOrphaned {
                Label("No longer in library", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 68)
            }
        }
        .contentShape(.rect)
        .tag(item.id)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(Self.accessibilityIdentifier(for: item.id))
    }
}
