import Foundation

nonisolated extension EpisodeSearchTranscriptDocument {
    init(_ document: EpisodeTranscriptDocument) {
        let version = document.normalizedTranscriptSHA256
            ?? [
                String(document.schemaVersion),
                document.sourceFileSHA256,
                document.modelIdentifier,
                document.modelVersion,
                String(document.updatedAt.timeIntervalSince1970),
            ].joined(separator: "|")
        self.init(
            episodeID: document.episodeID,
            podcastID: document.podcastID,
            version: version,
            segments: document.segments.map { segment in
                EpisodeSearchTranscriptSegment(
                    segmentID: String(segment.id),
                    startSeconds: segment.start,
                    endSeconds: segment.end,
                    text: segment.text
                )
            }
        )
    }
}
