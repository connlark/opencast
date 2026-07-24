import SwiftUI

struct EpisodeArtworkZoomView: View {
    private static let minimumScale: CGFloat = 1
    private static let maximumScale: CGFloat = 4
    private static let zoomStep: CGFloat = 0.5
    private static let targetPixelSize = CGSize(width: 2_048, height: 2_048)

    @Environment(OpenCastAppModel.self) private var appModel
    @GestureState private var gestureMagnification: CGFloat = 1
    @State private var settledScale: CGFloat = 1

    let episodeID: String

    private var episode: EpisodeListItemSnapshot? {
        appModel.episodeSnapshot(for: episodeID)
    }

    var body: some View {
        Group {
            if let episode {
                artworkContent(episode)
            } else {
                ContentUnavailableView("Episode Not Found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("Artwork")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if settledScale > Self.minimumScale {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset Zoom", systemImage: "arrow.counterclockwise", action: resetZoom)
                }
            }
        }
    }

    private func artworkContent(_ episode: EpisodeListItemSnapshot) -> some View {
        GeometryReader { proxy in
            let artworkLength = max(min(proxy.size.width, proxy.size.height) - 32, 0)

            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    ArtworkPlaceholder(
                        title: episode.podcastTitle,
                        imageURL: episode.artworkURL,
                        size: artworkLength,
                        targetPixelSize: Self.targetPixelSize,
                        cacheKind: .episode,
                        preview: episode.artworkPreview,
                        onPreviewResolved: updateArtworkPreview
                    )
                }
                .frame(width: artworkLength, height: artworkLength)
                .scaleEffect(resolvedScale)
                .frame(
                    width: artworkLength * resolvedScale,
                    height: artworkLength * resolvedScale
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Artwork for \(episode.title)")
                .accessibilityValue(
                    Double(settledScale).formatted(.percent.precision(.fractionLength(0)))
                )
                .accessibilityAddTraits(.isImage)
                .accessibilityAdjustableAction(adjustZoom)
                .accessibilityIdentifier("Zoomable Episode Artwork")
            }
            .defaultScrollAnchor(.center)
            .scrollIndicators(.hidden)
            .gesture(magnifyGesture)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
    }

    private var resolvedScale: CGFloat {
        (settledScale * gestureMagnification).clamped(
            to: Self.minimumScale...Self.maximumScale
        )
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($gestureMagnification) { value, magnification, _ in
                magnification = value.magnification
            }
            .onEnded { value in
                settledScale = (settledScale * value.magnification).clamped(
                    to: Self.minimumScale...Self.maximumScale
                )
            }
    }

    private func resetZoom() {
        withAnimation(.smooth) {
            settledScale = Self.minimumScale
        }
    }

    private func adjustZoom(_ direction: AccessibilityAdjustmentDirection) {
        let adjustment: CGFloat
        switch direction {
        case .increment:
            adjustment = Self.zoomStep
        case .decrement:
            adjustment = -Self.zoomStep
        @unknown default:
            adjustment = 0
        }

        withAnimation(.smooth) {
            settledScale = (settledScale + adjustment).clamped(
                to: Self.minimumScale...Self.maximumScale
            )
        }
    }

    private func updateArtworkPreview(_ preview: ArtworkPreview) {
        guard let episode else {
            return
        }

        appModel.library.updateArtworkPreview(preview, for: episode)
    }
}
