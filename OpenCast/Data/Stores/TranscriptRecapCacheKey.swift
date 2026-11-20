import CryptoKit
import Foundation

nonisolated struct TranscriptRecapCacheKey: Hashable, Codable, Sendable {
    static let playheadBucketSpan: TimeInterval = 30

    var episodeID: String
    var transcriptFingerprint: String
    var kind: TranscriptRecapWindowKind
    var playheadBucket: Int
    var promptVersion: Int
    var modelIdentifier: String

    init(
        document: EpisodeTranscriptDocument,
        kind: TranscriptRecapWindowKind,
        playhead: TimeInterval,
        promptVersion: Int = TranscriptIntelligencePrompts.promptVersion,
        modelIdentifier: String
    ) {
        episodeID = document.episodeID
        transcriptFingerprint = Self.transcriptFingerprint(for: document)
        self.kind = kind
        playheadBucket = Int((max(playhead, 0) / Self.playheadBucketSpan).rounded(.down))
        self.promptVersion = promptVersion
        self.modelIdentifier = modelIdentifier
    }

    var fileName: String {
        let joined = [
            episodeID, transcriptFingerprint, kind.rawValue, "\(playheadBucket)", "\(promptVersion)", modelIdentifier
        ].joined(separator: "|")
        return Self.sha256(joined) + ".json"
    }

    /// Changes whenever the document changes in a way that could move a segment.
    static func transcriptFingerprint(for document: EpisodeTranscriptDocument) -> String {
        sha256([
            document.sourceFileSHA256,
            document.modelIdentifier,
            document.modelVersion,
            document.modelTreeSHA256,
            document.normalizedTranscriptSHA256 ?? "",
            document.updatedAt.ISO8601Format(),
            "\(document.segments.count)"
        ].joined(separator: "|"))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
