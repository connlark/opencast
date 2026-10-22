import AVFoundation
import Foundation
import Testing
@testable import OpenCastPlayback

@Suite("AVAssetChapterReader")
struct AVAssetChapterReaderTests {
    @Test("Reads ID3 chapters with titles and bounds")
    func readsChapters() async throws {
        let chapters = try await AVAssetChapterReader.chapters(in: AVURLAsset(url: fixture("ChapteredSilence.mp3")))

        #expect(chapters.map(\.id) == [0, 1, 2])
        #expect(chapters.map(\.title) == ["Intro", "Middle", "Outro"])
        #expect(chapters.map(\.startTime) == [0, 1, 2])
        #expect(chapters.map(\.endTime) == [1, 2, 3])
    }

    @Test("Returns empty for audio without a tag")
    func noTag() async throws {
        let chapters = try await AVAssetChapterReader.chapters(in: AVURLAsset(url: fixture("UntaggedSilence.mp3")))
        #expect(chapters.isEmpty)
    }

    /// Silent 8 kHz MP3s made with ffmpeg; the chaptered one carries three
    /// one-second ID3v2.3 `CHAP` frames and a `CTOC`.
    private func fixture(_ name: String) -> URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")
    }
}
