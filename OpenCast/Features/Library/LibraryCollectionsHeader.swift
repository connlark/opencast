import SwiftUI

/// The Playlists and Up Next rows above the Library's shows. Playlists pushes
/// the collection; Up Next opens the queue sheet, so it has no chevron.
struct LibraryCollectionsHeader: View {
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 30.0

    let playlistCount: Int
    let upNextCount: Int
    let onOpenUpNext: () -> Void

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
        }
    }

    private static func accessibilityValue(for count: Int) -> String {
        count > 0 ? count.formatted() : ""
    }
}

#Preview {
    NavigationStack {
        ScrollView {
            LibraryCollectionsHeader(playlistCount: 3, upNextCount: 0, onOpenUpNext: {})
                .padding(.horizontal, 20)
        }
        .navigationTitle("Library")
    }
}
