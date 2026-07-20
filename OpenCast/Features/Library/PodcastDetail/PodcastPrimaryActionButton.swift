import SwiftUI

struct PodcastPrimaryActionButton: View {
    let action: PodcastPrimaryAction
    let onPlay: (EpisodeListItemSnapshot) -> Void

    var body: some View {
        Button(action: play) {
            Label(action.title, systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .accessibilityHint(action.episode.title)
    }

    private func play() {
        onPlay(action.episode)
    }
}
