import SwiftData
import SwiftUI

/// The tab accessory's Up Next variant: with nothing loaded and episodes
/// queued, it names the queue head and starts the queue in place, where the
/// mini player then takes over.
struct UpNextAccessoryView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(TabAccessoryGeometryStore.self) private var accessoryStore: TabAccessoryGeometryStore?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.tabViewBottomAccessoryPlacement) private var tabAccessoryPlacement
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let onOpenQueue: () -> Void

    @State private var playFeedback = 0

    var body: some View {
        if let episode = appModel.upNextAccessoryEpisode {
            let queuedCount = appModel.upNextQueue.items.count
            let isDense = TabAccessoryRow(geometry: accessoryGeometry, isInline: isInline) == .dense
            // Nothing is playing, so there is no scrubber: the wide row is the
            // standard row, its spare width going to the title.
            let metrics = isDense ? TabAccessoryRow.dense.metrics : TabAccessoryRow.standard.metrics
            HStack(spacing: isInline ? 4 : metrics.controlSpacing) {
                Button(action: onOpenQueue) {
                    HStack(spacing: isInline ? 10 : metrics.artworkTitleSpacing) {
                        ArtworkPlaceholder(
                            title: episode.podcastTitle,
                            imageURL: episode.artworkURL,
                            size: isInline ? 30 : metrics.artworkSide,
                            cacheKind: .episode
                        )
                        .accessibilityHidden(true)

                        MiniPlayerMetadataView(
                            title: episode.title,
                            podcastTitle: UpNextAccessoryText.subtitle(queuedCount: queuedCount),
                            showsSecondaryLine: !isDense
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
            .padding(.horizontal, isInline ? 8 : metrics.horizontalPadding)
            .padding(.vertical, isInline ? 0 : metrics.verticalPadding)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(isInline ? "up-next-accessory-inline" : "up-next-accessory-expanded")
            .accessibilityHidden(appModel.isNowPlayingPresented)
            .onChange(of: accessoryGeometry, initial: true) { _, geometry in
                TabAccessoryRow.log(accessory: "up-next", geometry: geometry, isInline: isInline)
            }
            .tabAccessoryRowContainer()
        }
    }

    private var isInline: Bool {
        tabAccessoryPlacement == .inline
    }

    /// The accessory's own measured geometry, published by the tab root;
    /// absent outside the tab view.
    private var accessoryGeometry: TabAccessoryGeometry {
        accessoryStore?.geometry ?? .absent
    }

    private func playUpNext() {
        playFeedback += 1
        appModel.advanceToNextQueuedEpisode(modelContext: modelContext)
    }
}
