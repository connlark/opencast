import SwiftUI

struct PlaylistOrganizerShowChoiceRow: View {
    let choice: PlaylistOrganizerShowChoice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ArtworkPlaceholder(
                    title: choice.title,
                    imageURL: choice.artworkURL,
                    size: 48,
                    preview: choice.artworkPreview
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                    Text(PlaylistOrganizerCopy.episodeCount(choice.episodeCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!choice.isEligible)
        .accessibilityHint(choice.isEligible ? "" : PlaylistOrganizerCopy.ineligibleShowHint)
        .accessibilityIdentifier("playlist-organizer-show-\(choice.podcastID)")
    }
}
