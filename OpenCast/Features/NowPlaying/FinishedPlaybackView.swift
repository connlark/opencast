import SwiftUI

struct FinishedPlaybackView: View {
    @AccessibilityFocusState private var isFinishedStatusAccessibilityFocused: Bool

    let presentation: FinishedPlaybackPresentation
    let metrics: NowPlayingContentMetrics
    let onReplay: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: metrics.contentSpacing) {
            ArtworkPlaceholder(
                title: presentation.episode.podcastTitle,
                imageURL: presentation.episode.artworkURL,
                size: metrics.artworkSize,
                cacheKind: .episode,
                preview: presentation.episode.artworkPreview
            )

            VStack(spacing: metrics.metadataSpacing) {
                Text(presentation.episode.title)
                    .font(metrics.titleFont)
                    .multilineTextAlignment(.center)
                    .lineLimit(metrics.titleLineLimit)
                    .minimumScaleFactor(metrics.titleMinimumScaleFactor)
                    .fixedSize(horizontal: false, vertical: true)

                Text(presentation.episode.podcastTitle)
                    .font(metrics.podcastFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(metrics.podcastLineLimit)
                    .minimumScaleFactor(metrics.podcastMinimumScaleFactor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Finished", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isFinishedStatusAccessibilityFocused)

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Replay", systemImage: "arrow.counterclockwise", action: onReplay)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)

                    Button("Done", systemImage: "checkmark", action: onDone)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: metrics.contentWidth)
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, metrics.topContentPadding)
        .padding(.bottom, metrics.bottomContentPadding)
        .frame(maxWidth: .infinity)
        .frame(minHeight: metrics.containerHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Finished")
        .accessibilityIdentifier("Finished Playback")
        .task(id: presentation.episode.episodeID) {
            // Land VoiceOver on the status heading (the alert pattern) so the
            // state change is spoken before the actions. A ScreenChanged
            // notification with a string argument would reset focus to the
            // first on-screen element and race this move.
            await Task.yield()
            isFinishedStatusAccessibilityFocused = true
        }
    }
}
