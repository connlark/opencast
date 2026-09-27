import SwiftData
import SwiftUI

/// The tab accessory's Up Next variant: with nothing loaded and episodes
/// queued, it names the queue head and starts the queue in place, where the
/// mini player then takes over.
struct UpNextAccessoryView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.tabViewBottomAccessoryPlacement) private var tabAccessoryPlacement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let isNowPlayingPresented: Bool
    let onOpenQueue: () -> Void

    @State private var playFeedback = 0

    var body: some View {
        if let episode = appModel.upNextAccessoryEpisode {
            let queuedCount = appModel.upNextQueue.items.count
            HStack(spacing: isInline ? 4 : 8) {
                Button(action: onOpenQueue) {
                    HStack(spacing: 10) {
                        ArtworkPlaceholder(
                            title: episode.podcastTitle,
                            imageURL: episode.artworkURL,
                            size: isInline ? 30 : 38,
                            cacheKind: .episode
                        )
                        .accessibilityHidden(true)

                        MiniPlayerMetadataView(
                            title: episode.title,
                            podcastTitle: UpNextAccessoryText.subtitle(queuedCount: queuedCount)
                        )
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Up Next")
                .accessibilityValue(
                    "\(episode.title), \(episode.podcastTitle); \(UpNextAccessoryText.queuedEpisodes(queuedCount))"
                )

                Button(action: playUpNext) {
                    Label("Play Up Next", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .font(dynamicTypeSize.isAccessibilitySize ? .caption : .title3)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityInputLabels(["Play Up Next", "Play"])
            }
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 0 : 6)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(isInline ? "up-next-accessory-inline" : "up-next-accessory-expanded")
            .accessibilityHidden(isNowPlayingPresented)
        }
    }

    private var isInline: Bool {
        tabAccessoryPlacement == .inline
    }

    private func playUpNext() {
        playFeedback += 1
        appModel.advanceToNextQueuedEpisode(modelContext: modelContext)
    }
}
