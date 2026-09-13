import Foundation
import Testing
@testable import OpenCast

@Suite("Resume widget snapshots")
struct ResumeWidgetSnapshotTests {
    @Test func freshStaleAbsentAndRemovedSnapshots() throws {
        let directory = URL.temporaryDirectory.appending(path: "widget-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ResumeWidgetSnapshot.read(from: directory) == nil)
        let value = snapshot()
        let file = directory.appending(path: ResumeWidgetSnapshot.filename)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        #expect(try ResumeWidgetSnapshot.read(from: directory) == value)
        #expect(!value.isStale(at: value.updatedAt))
        #expect(value.isStale(at: value.updatedAt.addingTimeInterval(ResumeWidgetSnapshot.staleInterval + 1)))
        try FileManager.default.removeItem(at: file)
        #expect(try ResumeWidgetSnapshot.read(from: directory) == nil)
    }

    @Test func corruptAndOversizedSnapshotsAreRejected() throws {
        let directory = URL.temporaryDirectory.appending(path: "widget-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: ResumeWidgetSnapshot.filename)
        try Data(repeating: 0, count: ResumeWidgetSnapshot.maximumBytes + 1).write(to: file)
        #expect(throws: (any Error).self) { try ResumeWidgetSnapshot.read(from: directory) }
        try Data("{}".utf8).write(to: file)
        #expect(throws: (any Error).self) { try ResumeWidgetSnapshot.read(from: directory) }
    }

    @Test func appOpeningRoutePreservesExactEpisodeAndRejectsBadURLs() throws {
        let value = snapshot()
        #expect(ResumeWidgetRoute.action(for: try #require(value.resumeURL)) == .playEpisode(value.episodeID))
        #expect(ResumeWidgetRoute.action(for: URL(string: "opencast://resume?episode=one&episode=two")!) == nil)
        #expect(ResumeWidgetRoute.action(for: URL(string: "https://resume?episode=one")!) == nil)
        #expect(ResumeWidgetRoute.action(for: URL(string: "opencast://resume")!) == nil)
    }

    private func snapshot() -> ResumeWidgetSnapshot {
        ResumeWidgetSnapshot(episodeID: "stable-episode-id", title: "An Episode", showTitle: "A Show", updatedAt: .now, progressBucket: 4, artwork: nil)
    }
}
