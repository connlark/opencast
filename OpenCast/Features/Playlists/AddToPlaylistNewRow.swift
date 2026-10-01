import SwiftUI

/// The picker's first row: names a new playlist that starts out holding the
/// episode.
struct AddToPlaylistNewRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)

                Text("New Playlist…")
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Add to Playlist New Playlist")
    }
}

#Preview("Dark") {
    List {
        AddToPlaylistNewRow(action: {})
    }
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    List {
        AddToPlaylistNewRow(action: {})
    }
    .preferredColorScheme(.light)
}
