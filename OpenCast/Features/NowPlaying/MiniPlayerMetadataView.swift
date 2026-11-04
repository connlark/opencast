import SwiftUI

struct MiniPlayerMetadataView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let podcastTitle: String
    var playlistSource: PlaylistPlaybackSource? = nil
    var playlistRemainingCount = 0
    /// Off in the dense row: the title alone, on one line. The caller keeps
    /// the second line's text in its accessibility value.
    var showsSecondaryLine = true

    var body: some View {
        Group {
            if !showsSecondaryLine {
                Text(title)
                    .font(dynamicTypeSize.isAccessibilitySize ? .caption : .subheadline)
                    .foregroundStyle(.primary)
            } else if dynamicTypeSize.isAccessibilitySize {
                // The system accessory has a fixed height. A scaled single
                // line stays readable; VoiceOver receives both full titles.
                Text("\(title), \(podcastTitle)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    secondaryLine
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var secondaryLine: some View {
        if let playlistSource {
            // The count keeps layout priority so a long playlist name
            // truncates before "N left" does.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(Image(systemName: "music.note.list")) \(playlistSource.name)")
                if playlistRemainingCount >= 1 {
                    Text(PlaylistPlaybackSourceText.miniPlayerRemainingSegment(remainingCount: playlistRemainingCount))
                        .layoutPriority(1)
                }
            }
        } else {
            Text(podcastTitle)
        }
    }
}
