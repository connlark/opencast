import SwiftUI

/// The top of a playlist's detail screen: the cover, the name, a meta line,
/// how much there is to hear, and Play. A manual playlist says when it last
/// changed and puts Shuffle beside Play. A smart playlist wears its tint,
/// shows its rule chips under the count line (or a footnote when the rule
/// came from a newer version of the app) and has Play alone. With episodes
/// already in Up Next, Play and Shuffle first ask whether to replace the
/// queue or add the playlist after it.
struct PlaylistHeroHeader: View {
    private static let coverSide = 160.0

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isConfirmingPlay = false
    @State private var isConfirmingShuffle = false
    @State private var replaceQueuedCount = 0

    let summary: PlaylistSummary
    let itemCount: Int
    let totalDuration: TimeInterval
    /// Manual playlists only. A smart playlist passes nil so its line never
    /// becomes "unplayed of": its rule already decides what it lists.
    let counts: PlaylistCounts?
    let sources: PlaylistCoverSources
    let primaryAction: PlaylistPrimaryAction
    let canPlay: Bool
    let onPlay: (PlaylistPlayMode) -> Void
    /// Nil hides Shuffle: a smart playlist's rule decides its order.
    var onShuffle: ((PlaylistPlayMode) -> Void)?
    var onRuleChange: (PlaylistRule) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 16) {
            PlaylistCoverView(summary: summary, sources: sources, cornerRadius: 14)
                .frame(width: Self.coverSide, height: Self.coverSide)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)

            VStack(spacing: 5) {
                Text(summary.name)
                    .font(.title2)
                    .bold()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                metaLine
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 8) {
                countLine
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("Playlist Count Line")

                ruleControls
            }

            playbackButtons
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .tint(summary.tint?.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Playlist Hero Header")
    }

    @ViewBuilder
    private var metaLine: some View {
        // Only the glyph takes the tint: the playlist's own colour is too
        // light to read as text on its glow (yellow, orange, green, teal).
        if summary.kind == .smart {
            Label {
                Text("Smart Playlist")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
            }
        } else {
            Text("Playlist · Updated \(summary.updatedAt.formatted(.relative(presentation: .named)))")
                .foregroundStyle(.secondary)
        }
    }

    // The meta line above already says "Smart Playlist", so the spoken count
    // leaves that prefix off.
    @ViewBuilder
    private var countLine: some View {
        if summary.kind == .smart {
            Text(PlaylistSummaryText.smartLine(itemCount: itemCount, totalDuration: totalDuration))
                .accessibilityLabel(PlaylistSummaryText.spokenLine(itemCount: itemCount, totalDuration: totalDuration))
        } else {
            PlaylistSummaryText(itemCount: itemCount, totalDuration: totalDuration, counts: counts)
        }
    }

    @ViewBuilder
    private var ruleControls: some View {
        if summary.kind == .smart {
            if let rule = summary.rule {
                SmartPlaylistRuleChips(rule: rule, onChange: onRuleChange)
            } else {
                Text("These rules need a newer version of the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var playbackButtons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))

        return GlassEffectContainer(spacing: 12) {
            layout {
                Button(action: playTapped) {
                    Label(primaryAction.title, systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(summary.tint?.prominentLabelColor ?? .white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("Playlist Play")
                .playlistReplaceConfirmation(
                    isPresented: $isConfirmingPlay,
                    queuedCount: replaceQueuedCount,
                    onChoose: onPlay
                )

                if let onShuffle {
                    Button(action: shuffleTapped) {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("Playlist Shuffle")
                    .playlistReplaceConfirmation(
                        isPresented: $isConfirmingShuffle,
                        queuedCount: replaceQueuedCount,
                        onChoose: onShuffle
                    )
                }
            }
            .controlSize(.large)
            .disabled(!canPlay)
        }
    }

    // The queue is read at tap time rather than in `body` so the detail screen
    // does not re-render on every Up Next change.
    private func playTapped() {
        replaceQueuedCount = appModel.upNextQueue.items.count
        if replaceQueuedCount > 0 {
            isConfirmingPlay = true
        } else {
            onPlay(.replace)
        }
    }

    private func shuffleTapped() {
        replaceQueuedCount = appModel.upNextQueue.items.count
        if replaceQueuedCount > 0 {
            isConfirmingShuffle = true
        } else {
            onShuffle?(.replace)
        }
    }
}
