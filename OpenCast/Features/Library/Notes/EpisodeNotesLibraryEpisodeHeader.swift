import SwiftUI

/// An episode's header in the Notes library: artwork, show and episode title.
/// It opens the episode while the episode resolves; once the episode has
/// left the library it keeps the titles the notes stored and says why it no
/// longer opens.
struct EpisodeNotesLibraryEpisodeHeader: View {
    let group: EpisodeNotesLibraryGroup
    let onOpen: (String) -> Void

    var body: some View {
        if group.isResolved {
            Button(action: open) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            ArtworkPlaceholder(
                title: group.podcastTitle,
                imageURL: group.artworkURL,
                size: 44,
                cacheKind: .episode
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(group.podcastTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(group.episodeTitle)
                    .font(.headline)
                    .lineLimit(2)
                if !group.isResolved {
                    Label("No longer in your library", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if group.isResolved {
                Image(systemName: "chevron.forward")
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
    }

    private var accessibilityIdentifier: String {
        "notes-library-episode-\(group.episodeID)"
    }

    private func open() {
        onOpen(group.episodeID)
    }
}
