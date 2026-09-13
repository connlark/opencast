import Foundation
import Testing
@testable import OpenCast

struct ResumeWidgetPublisherTests {
    @Test func removingContentInvalidatesAnInFlightArtworkRequest() async throws {
        let directory = URL.temporaryDirectory.appending(path: "widget-publisher-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = ResumeWidgetArtworkGate()
        let publisher = ResumeWidgetPublisher(directory: directory, loadArtwork: { url in
            if url != nil { return await gate.load() }
            return nil
        }, reload: {})
        await publisher.publish(nil)
        let candidate = ResumeWidgetCandidate(episodeID: "episode", title: "Episode", showTitle: "Show", artworkURL: URL(string: "https://example.com/art.jpg"), artworkRevision: nil, progressBucket: 0, isPlaying: false)
        let pending = Task { await publisher.publish(candidate) }
        await gate.waitUntilStarted()
        await publisher.publish(nil)
        await gate.complete()
        await pending.value
        #expect(try ResumeWidgetSnapshot.read(from: directory) == nil)
    }
}
