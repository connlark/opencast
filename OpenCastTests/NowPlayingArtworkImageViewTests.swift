import CoreGraphics
import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Now Playing artwork image view")
struct NowPlayingArtworkImageViewTests {
    @Test("Wide artwork uses black letterbox backing")
    func wideArtworkUsesBlackLetterboxBacking() throws {
        let renderer = ImageRenderer(
            content: NowPlayingArtworkImageView(
                title: "Wide",
                image: try artworkTestWideSplitImage(width: 20, height: 10)
            )
            .frame(width: 20, height: 20)
            .background(.white)
        )
        renderer.scale = 1
        renderer.isOpaque = true

        let image = try #require(renderer.uiImage)
        let topPixel = try artworkTestPixel(in: image, x: 10, y: 2)
        let leftPixel = try artworkTestPixel(in: image, x: 2, y: 10)
        let rightPixel = try artworkTestPixel(in: image, x: 17, y: 10)

        #expect(topPixel.red < 10)
        #expect(topPixel.green < 10)
        #expect(topPixel.blue < 10)
        #expect(topPixel.alpha == 255)
        #expect(leftPixel.red > 200)
        #expect(leftPixel.blue < 80)
        #expect(rightPixel.red < 80)
        #expect(rightPixel.blue > 200)
    }
}
