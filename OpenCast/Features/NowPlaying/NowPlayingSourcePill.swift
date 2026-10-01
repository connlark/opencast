import SwiftUI

/// The glass capsule above the Now Playing title naming the playlist playback
/// came from. The capsule stays footnote-sized; the 44 pt frame around it is
/// the tap target.
struct NowPlayingSourcePill: View {
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
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PlaylistPlaybackSourceText.pillLabel(name: name))
        .accessibilityHint("Opens the playlist")
        .accessibilityIdentifier("Now Playing Source")
    }
}
