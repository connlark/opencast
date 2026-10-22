import Foundation
import OpenCastCore

nonisolated struct PlaybackChapterList: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case embedded
        case generated(transcriptSourceSHA256: String)
    }

    static let restartThreshold: TimeInterval = 3

    /// Sorted by start time.
    let chapters: [EpisodeChapter]
    let source: Source

    static let empty = PlaybackChapterList(chapters: [], source: .embedded)

    init(chapters: [EpisodeChapter], source: Source) {
        self.chapters = chapters.sorted { $0.startTime < $1.startTime }
        self.source = source
    }

    var isEmpty: Bool {
        chapters.isEmpty
    }

    func chapter(at position: TimeInterval) -> EpisodeChapter? {
        chapters.last { $0.startTime <= position }
    }

    func ordinal(of chapter: EpisodeChapter) -> Int? {
        chapters.firstIndex(of: chapter).map { $0 + 1 }
    }

    func nextChapter(after position: TimeInterval) -> EpisodeChapter? {
        chapters.first { $0.startTime > position }
    }

    func previousChapter(before position: TimeInterval) -> EpisodeChapter? {
        guard let current = chapter(at: position) else {
            return nil
        }
        if position - current.startTime > Self.restartThreshold {
            return current
        }
        // Chapters that share a start would bounce between themselves:
        // step back to the last strictly earlier start.
        return chapters.last { $0.startTime < current.startTime }
    }

    var timelineMarkers: [TimeInterval] {
        chapters.map(\.startTime).filter { $0 > 0 }
    }
}
