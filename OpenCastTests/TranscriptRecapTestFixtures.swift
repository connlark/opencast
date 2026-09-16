import Foundation
import OpenCastTranscription
@testable import OpenCast

nonisolated enum TranscriptRecapTestFixtures {
    /// Consecutive segments of `duration` seconds each, ids from 0, with
    /// deterministic filler text of roughly `textLength` characters.
    static func segments(
        count: Int,
        duration: TimeInterval = 10,
        textLength: Int = 40
    ) -> [OpenCastTranscriptSegment] {
        (0..<count).map { index in
            let base = "Segment \(index) says something about topic \(index % 7). "
            let text = String(repeating: base, count: max(1, textLength / base.count))
            return OpenCastTranscriptSegment(
                id: index,
                start: Double(index) * duration,
                end: Double(index + 1) * duration,
                text: text,
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        }
    }

    static func document(
        segments: [OpenCastTranscriptSegment],
        episodeID: String = "episode-1",
        updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> EpisodeTranscriptDocument {
        EpisodeTranscriptDocument(
            schemaVersion: EpisodeTranscriptDocument.currentSchemaVersion,
            episodeID: episodeID,
            podcastID: "https://example.com/feed.xml",
            sourceAudioURL: "https://example.com/\(episodeID).mp3",
            sourceFileByteCount: 1,
            sourceFileSHA256: "source-sha",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: segments.last?.end ?? 0,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    /// The scripted client's tokenizer.
    static func tokenCount(_ text: String) async throws -> Int {
        text.count / 4
    }

    static func recapJSON(citing ids: [Int]) -> String {
        let bullets = ids.enumerated().map { index, id in
            "{\"text\":\"Bullet \(index) about segment \(id).\",\"segmentID\":\(id)}"
        }
        return "{\"bullets\":[\(bullets.joined(separator: ","))]}"
    }
}
