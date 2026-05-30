import SwiftUI

struct NowPlayingMetalPeelArtworkView: UIViewRepresentable {
    let artworkImage: UIImage
    let progress: CGFloat
    let touchY: CGFloat
    let isInteracting: Bool
    let settleTarget: CGFloat
    let settleVelocity: CGFloat
    let settleRequestID: Int
    let reduceMotion: Bool
    let onProgressChanged: @MainActor (CGFloat) -> Void

    func makeUIView(context: Context) -> NowPlayingMetalPeelUIView {
        let view = NowPlayingMetalPeelUIView()
        view.update(
            artworkImage: artworkImage,
            progress: progress,
            touchY: touchY,
            isInteracting: isInteracting,
            settleTarget: settleTarget,
            settleVelocity: settleVelocity,
            settleRequestID: settleRequestID,
            reduceMotion: reduceMotion,
            onProgressChanged: onProgressChanged
        )
        return view
    }

    func updateUIView(_ view: NowPlayingMetalPeelUIView, context: Context) {
        view.update(
            artworkImage: artworkImage,
            progress: progress,
            touchY: touchY,
            isInteracting: isInteracting,
            settleTarget: settleTarget,
            settleVelocity: settleVelocity,
            settleRequestID: settleRequestID,
            reduceMotion: reduceMotion,
            onProgressChanged: onProgressChanged
        )
    }

    static func dismantleUIView(_ view: NowPlayingMetalPeelUIView, coordinator: ()) {
        view.stopRendering()
    }
}
