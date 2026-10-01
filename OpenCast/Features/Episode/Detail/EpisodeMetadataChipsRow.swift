import SwiftUI

struct EpisodeMetadataChipsRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let chips: [EpisodeMetadataChip]
    var onOpenPlaylists: () -> Void = {}

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        let staticChips = self.staticChips

        layout {
            if !staticChips.isEmpty {
                layout {
                    ForEach(staticChips) { chip in
                        styledChip(chipView(chip))
                    }
                }
                .accessibilityElement(children: .combine)
            }

            // A sibling of the combined static chips, so VoiceOver keeps it
            // as its own button instead of folding it into their summary.
            if let playlistCount {
                Button(action: onOpenPlaylists) {
                    // The capsule stays caption-sized; the frame is the tap target.
                    styledChip(Label("^[\(playlistCount) Playlist](inflect: true)", systemImage: "music.note.list"))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the playlists for this episode")
                .accessibilityIdentifier("Episode Playlists Chip")
            }
        }
    }

    private var staticChips: [EpisodeMetadataChip] {
        chips.filter { chip in
            if case .playlists = chip {
                return false
            }
            return true
        }
    }

    private var playlistCount: Int? {
        for chip in chips {
            if case .playlists(let count) = chip {
                return count
            }
        }
        return nil
    }

    private func styledChip(_ content: some View) -> some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.fill.tertiary, in: .capsule)
    }

    @ViewBuilder
    private func chipView(_ chip: EpisodeMetadataChip) -> some View {
        switch chip {
        case .publishDate(let date):
            Text(date, format: .dateTime.month(.abbreviated).day().year())
        case .duration(let text):
            Text(text)
        case .remaining(let text, let fractionCompleted):
            HStack(spacing: 6) {
                EpisodeProgressBarView(fractionCompleted: fractionCompleted)
                    .frame(width: 44)
                Text(text)
            }
        case .downloaded(let fileSize):
            Label(fileSize ?? "Downloaded", systemImage: "arrow.down.circle.fill")
                .accessibilityLabel(fileSize.map { "Downloaded, \($0)" } ?? "Downloaded")
        case .played:
            Label("Played", systemImage: "checkmark")
        case .playlists:
            // Drawn as its own button in `body`.
            EmptyView()
        }
    }
}

#Preview("Dark") {
    EpisodeMetadataChipsRow(chips: [
        .publishDate(Date(timeIntervalSince1970: 1_780_000_000)),
        .remaining("2h 47m left", fractionCompleted: 0.3),
        .downloaded(fileSize: "42 MB"),
        .played,
        .playlists(count: 2)
    ])
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    EpisodeMetadataChipsRow(chips: [
        .publishDate(Date(timeIntervalSince1970: 1_780_000_000)),
        .duration("2h 47m"),
        .downloaded(fileSize: nil)
    ])
    .padding()
    .preferredColorScheme(.light)
}
