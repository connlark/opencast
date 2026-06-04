import CoreGraphics
import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing artwork canvas")
struct NowPlayingArtworkCanvasTests {
    @Test("Canvas size uses the longest artwork edge")
    func canvasSizeUsesLongestArtworkEdge() {
        let size = NowPlayingArtworkCanvas.squareSize(for: CGSize(width: 940, height: 705))

        #expect(size == CGSize(width: 940, height: 940))
    }

    @Test("Wide artwork is letterboxed vertically in a square canvas")
    func wideArtworkIsLetterboxedVerticallyInSquareCanvas() {
        let rect = NowPlayingArtworkCanvas.aspectFitRect(
            imageSize: CGSize(width: 940, height: 705),
            canvasSize: CGSize(width: 940, height: 940)
        )

        expect(rect, isApproximately: CGRect(x: 0, y: 117.5, width: 940, height: 705))
    }

    @Test("Tall artwork is letterboxed horizontally in a square canvas")
    func tallArtworkIsLetterboxedHorizontallyInSquareCanvas() {
        let rect = NowPlayingArtworkCanvas.aspectFitRect(
            imageSize: CGSize(width: 705, height: 940),
            canvasSize: CGSize(width: 940, height: 940)
        )

        expect(rect, isApproximately: CGRect(x: 117.5, y: 0, width: 705, height: 940))
    }

    @Test("Square artwork fills the square canvas")
    func squareArtworkFillsSquareCanvas() {
        let rect = NowPlayingArtworkCanvas.aspectFitRect(
            imageSize: CGSize(width: 512, height: 512),
            canvasSize: CGSize(width: 512, height: 512)
        )

        expect(rect, isApproximately: CGRect(x: 0, y: 0, width: 512, height: 512))
    }

    private func expect(
        _ rect: CGRect,
        isApproximately expected: CGRect,
        tolerance: CGFloat = 0.0001
    ) {
        #expect(abs(rect.origin.x - expected.origin.x) <= tolerance)
        #expect(abs(rect.origin.y - expected.origin.y) <= tolerance)
        #expect(abs(rect.size.width - expected.size.width) <= tolerance)
        #expect(abs(rect.size.height - expected.size.height) <= tolerance)
    }
}
