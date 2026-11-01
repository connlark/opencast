import SwiftUI

/// The Playlists, Up Next and Notes rows above the Library's shows.
/// Playlists and Notes push their screens; Up Next opens the queue sheet, so
/// it has no chevron. A nil `notesCount` (Show Note Button is off) hides the
/// Notes row.
struct LibraryCollectionsHeader: View {
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 30.0

    let playlistCount: Int
    let upNextCount: Int
    let notesCount: Int?
    let onOpenUpNext: () -> Void
    let onOpenNotes: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: AppRoute.playlists) {
                LibraryCollectionRow(
                    title: "Playlists",
                    systemImage: "music.note.list",
                    count: playlistCount,
                    iconWidth: iconWidth,
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)
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
                // In the Library list these rows share one list row, which a
                // second NavigationLink would also activate: tapping Notes
                // pushed Playlists beneath it. A button pushes Notes alone.
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
            LibraryCollectionsHeader(playlistCount: 3, upNextCount: 0, notesCount: 2, onOpenUpNext: {}, onOpenNotes: {})
                .padding(.horizontal, 20)
        }
        .navigationTitle("Library")
    }
}
