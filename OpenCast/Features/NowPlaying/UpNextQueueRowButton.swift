import SwiftUI

struct UpNextQueueRowButton: View {
    let episode: EpisodeListItemSnapshot
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EpisodeRowView(episode: episode)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(EpisodeRowView.accessibilityIdentifier(for: episode.episodeID))
    }
}
