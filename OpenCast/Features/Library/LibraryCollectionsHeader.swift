import SwiftUI

/// The Playlists, Up Next and Notes rows above the Library's shows.
/// Playlists and Notes push their screens (in a two-pane split they open as
/// the detail and show the selection); Up Next opens the queue, so it has no
/// chevron. A nil `notesCount` (Show Note Button is off) hides the Notes row.
struct LibraryCollectionsHeader: View {
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 30.0

    let playlistCount: Int
    let upNextCount: Int
    let notesCount: Int?
    let onOpenPlaylists: () -> Void
    let onOpenUpNext: () -> Void
    let onOpenNotes: () -> Void

    var body: some View {
        // In the Library list these rows share one list row, so each is a
        // button. A link there is the row's selection instead: the row fires
        // every link in it, and a touch beside a button goes to the button.
        VStack(spacing: 0) {
            Button(action: onOpenPlaylists) {
                LibraryCollectionRow(
                    title: "Playlists",
                    systemImage: "music.note.list",
                    count: playlistCount,
                    iconWidth: iconWidth,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .twoPaneRootSelection(.playlists, style: .inline)
            .accessibilityValue(Self.accessibilityValue(for: playlistCount))
            .accessibilityIdentifier("Library Playlists Row")

            Divider()
                .padding(.leading, iconWidth + 14)

            Button(action: onOpenUpNext) {
                LibraryCollectionRow(
                    title: "Up Next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    count: upNextCount,
                    iconWidth: iconWidth,
                    showsChevron: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityValue(Self.accessibilityValue(for: upNextCount))
            .accessibilityIdentifier("Library Up Next Row")

            Divider()
                .padding(.leading, iconWidth + 14)

            if let notesCount {
                Button(action: onOpenNotes) {
                    LibraryCollectionRow(
                        title: "Notes",
                        systemImage: "note.text",
                        count: notesCount,
                        iconWidth: iconWidth,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .twoPaneRootSelection(.notes, style: .inline)
                .accessibilityValue(Self.accessibilityValue(for: notesCount))
                .accessibilityIdentifier("Library Notes Row")

                Divider()
                    .padding(.leading, iconWidth + 14)
            }
        }
    }

    private static func accessibilityValue(for count: Int) -> String {
        count > 0 ? count.formatted() : ""
    }
}

#Preview {
    NavigationStack {
        ScrollView {
            LibraryCollectionsHeader(
                playlistCount: 3,
                upNextCount: 0,
                notesCount: 2,
                onOpenPlaylists: {},
                onOpenUpNext: {},
                onOpenNotes: {}
            )
                .padding(.horizontal, 20)
        }
        .navigationTitle("Library")
    }
}
