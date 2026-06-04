import SwiftUI

struct ArtworkPreviewImage: View {
    let preview: ArtworkPreview

    var body: some View {
        Canvas { context, size in
            let fittedRect = aspectFitRect(in: size)
            let cellWidth = fittedRect.width / CGFloat(preview.pixelWidth)
            let cellHeight = fittedRect.height / CGFloat(preview.pixelHeight)

            preview.rgbData.withUnsafeBytes { rawBytes in
                let bytes = rawBytes.bindMemory(to: UInt8.self)
                guard bytes.count >= ArtworkPreview.requiredRGBByteCount(
                    width: preview.pixelWidth,
                    height: preview.pixelHeight
                ) else {
                    return
                }

                for row in 0..<preview.pixelHeight {
                    for column in 0..<preview.pixelWidth {
                        let offset = (row * preview.pixelWidth + column) * ArtworkPreview.rgbBytesPerPixel
                        let color = Color(
                            red: Double(bytes[offset]) / 255,
                            green: Double(bytes[offset + 1]) / 255,
                            blue: Double(bytes[offset + 2]) / 255
                        )
                        let rect = CGRect(
                            x: fittedRect.minX + CGFloat(column) * cellWidth,
                            y: fittedRect.minY + CGFloat(row) * cellHeight,
                            width: cellWidth,
                            height: cellHeight
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
    }

    private func aspectFitRect(in canvasSize: CGSize) -> CGRect {
        let imageSize = CGSize(width: CGFloat(preview.pixelWidth), height: CGFloat(preview.pixelHeight))
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
