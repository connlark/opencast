import CryptoKit
import Foundation

/// Everything that makes a cached recap reusable: the episode, the exact
/// transcript document, the window kind, the playhead to the nearest bucket,
/// and the prompt and model that produced it. Any change misses the cache.
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

    /// A transcript document that changes in any way that could move a
    /// segment (a new source file, model, or completed rewrite) changes this.
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
