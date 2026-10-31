import SwiftUI

/// One note as both the episode detail card and the Now Playing sheet row
/// show it: the timestamp (which seeks) above a button holding everything
/// else, which opens the editor.
struct EpisodeNoteRowContent: View {
    let note: EpisodeNoteRecord
    let onSeek: (TimeInterval) -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !note.isEpisodeWide {
                Button(action: seek) {
                    Label(note.timestamp.formattedPlaybackDuration, systemImage: "play.circle")
                        .font(.subheadline.monospacedDigit())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Play from \(note.timestamp.formattedPlaybackDuration)")
            }
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 8) {
                    if note.isEpisodeWide {
                        Label("Episode Note", systemImage: "note.text")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(note.text)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.text)
            .accessibilityValue(note.isEpisodeWide ? "Episode note" : "")
            .accessibilityHint("Edits this note")
        }
    }

    private func seek() {
        onSeek(note.timestamp)
    }
}
