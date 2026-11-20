import SwiftUI

struct NowPlayingSourcePill: View {
    static let height: CGFloat = 44
    static let minimumSpareHeight: CGFloat = height + 16

    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("Playing from \(Text(name).bold().foregroundStyle(Color.primary))")
                    .foregroundStyle(Color.secondary)
            } icon: {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular.interactive(), in: .capsule)
            .frame(minHeight: Self.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PlaylistPlaybackSourceText.pillLabel(name: name))
        .accessibilityHint("Opens the playlist")
        .accessibilityIdentifier("Now Playing Source")
    }
}
