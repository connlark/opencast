import Foundation
import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Transcript recap cache")
struct TranscriptRecapCacheTests {
    private let directory = URL.temporaryDirectory.appending(path: "recap-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let document = TranscriptRecapTestFixtures.document(segments: TranscriptRecapTestFixtures.segments(count: 60))

    private func key(
        document: EpisodeTranscriptDocument? = nil,
        kind: TranscriptRecapWindowKind = .lastFiveMinutes,
        playhead: TimeInterval = 400,
        promptVersion: Int = TranscriptIntelligencePrompts.promptVersion,
        modelIdentifier: String = "scripted"
    ) -> TranscriptRecapCacheKey {
        TranscriptRecapCacheKey(
            document: document ?? self.document,
            kind: kind,
            playhead: playhead,
            promptVersion: promptVersion,
            modelIdentifier: modelIdentifier
        )
    }

    private func result(playhead: TimeInterval = 400) -> TranscriptRecapResult {
        TranscriptRecapResult(
            kind: .lastFiveMinutes,
            playhead: playhead,
            windowStart: 100,
            windowEnd: playhead,
            windowSegmentCount: 30,
            windowTokenCount: 500,
            isWindowTruncated: false,
            bullets: [TranscriptRecapResultBullet(text: "A point.", segmentID: 12, start: 120)],
            droppedCitationCount: 1
        )
    }

    @Test("Entries round-trip and miss on every key component")
    func keying() throws {
        let cache = TranscriptRecapCache(directory: directory)
        defer { try? cache.removeAll() }
        #expect(try cache.entry(for: key()) == nil)

        let entry = TranscriptRecapCacheEntry(key: key(), result: result(), createdAt: .now)
        try cache.store(entry)
        #expect(try cache.entry(for: key())?.result == result())
        // Same 30 s bucket.
        #expect(try cache.entry(for: key(playhead: 419))?.result == result())

        #expect(try cache.entry(for: key(playhead: 420)) == nil)
        #expect(try cache.entry(for: key(kind: .soFar)) == nil)
        #expect(try cache.entry(for: key(promptVersion: TranscriptIntelligencePrompts.promptVersion + 1)) == nil)
        #expect(try cache.entry(for: key(modelIdentifier: "other-model")) == nil)
        #expect(try cache.entry(for: key(document: TranscriptRecapTestFixtures.document(segments: document.segments, episodeID: "episode-2"))) == nil)
    }

    @Test("A changed transcript document invalidates its recaps")
    func transcriptChangeInvalidates() throws {
        let cache = TranscriptRecapCache(directory: directory)
        defer { try? cache.removeAll() }
        try cache.store(TranscriptRecapCacheEntry(key: key(), result: result(), createdAt: .now))

        let rewritten = TranscriptRecapTestFixtures.document(
            segments: document.segments,
            updatedAt: document.updatedAt.addingTimeInterval(60)
        )
        #expect(try cache.entry(for: key(document: rewritten)) == nil)

        var regrown = document
        regrown.segments = TranscriptRecapTestFixtures.segments(count: 61)
        #expect(try cache.entry(for: key(document: regrown)) == nil)

        var resourced = document
        resourced.sourceFileSHA256 = "other-source"
        #expect(try cache.entry(for: key(document: resourced)) == nil)
    }

    @Test("Remove all wipes the directory and a later store recreates it")
    func removeAll() throws {
        let cache = TranscriptRecapCache(directory: directory)
        try cache.store(TranscriptRecapCacheEntry(key: key(), result: result(), createdAt: .now))
        try cache.removeAll()
        #expect(!FileManager.default.fileExists(atPath: directory.path()))
        #expect(try cache.entry(for: key()) == nil)
        try cache.store(TranscriptRecapCacheEntry(key: key(), result: result(), createdAt: .now))
        #expect(try cache.entry(for: key()) != nil)
        try cache.removeAll()
    }
}
