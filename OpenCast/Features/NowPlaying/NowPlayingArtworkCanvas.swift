import CoreGraphics

nonisolated enum NowPlayingArtworkCanvas {
    static func squareSize(for imageSize: CGSize) -> CGSize {
        let side = max(max(imageSize.width.rounded(.up), imageSize.height.rounded(.up)), 1)
        return CGSize(width: side, height: side)
    }

    static func aspectFitRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              canvasSize.width > 0,
              canvasSize.height > 0
        else {
            return CGRect(origin: .zero, size: canvasSize)
        }

        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (canvasSize.width - fittedSize.width) / 2,
            y: (canvasSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}
