#if DEBUG
import Foundation
import OpenCastTranscription
import SwiftData

/// Seeds a completed Chapters & Summary analysis for the primary episode so
/// episode detail renders the generated cards from records alone. Every
/// currency condition the analysis store checks is satisfied from the same
/// transcript document the transcript seed wrote: expected policy, matching
/// fingerprint, whole-second `transcriptUpdatedAt`, normalized segment count,
/// completed transcript state, and an on-disk document.
enum AppStoreScreenshotSeedChapters {
    static func seed(
        in context: ModelContext,
        transcriptDocument: EpisodeTranscriptDocument,
        createdAt: Date
    ) throws {
        let episodeID = transcriptDocument.episodeID
        let fileStore = EpisodeTranscriptAnalysisFileStore()
        let segments = OpenCastTranscriptSegmentNormalizer.normalized(transcriptDocument.segments)
        let fingerprint = fileStore.transcriptFingerprint(for: transcriptDocument, segments: segments)
        let relativePath = fileStore.relativePath(episodeID: episodeID, transcriptFingerprint: fingerprint)
        let chapters = chapters()

        // Marketing shots must never surface a vendor model name.
        let document = EpisodeTranscriptAnalysisDocument(
            schemaVersion: EpisodeTranscriptAnalysisContract.schemaVersion,
            episodeID: episodeID,
            podcastID: transcriptDocument.podcastID,
            requestID: "app-store-screenshot-transcript-analysis",
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcriptDocument.updatedAt,
            transcriptSegmentCount: segments.count,
            transcriptState: .completed,
            model: "",
            policy: EpisodeTranscriptAnalysisContract.expectedPolicy,
            chapters: chapters,
            summary: summary(),
            warnings: [],
            usage: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try fileStore.write(document, relativePath: relativePath)
        context.insert(EpisodeTranscriptAnalysisRecord(
            episodeID: episodeID,
            podcastID: transcriptDocument.podcastID,
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcriptDocument.updatedAt,
            transcriptSegmentCount: segments.count,
            transcriptState: .completed,
            state: .completed,
            analysisRelativePath: relativePath,
            model: document.model,
            policy: document.policy,
            chapterCount: chapters.count,
            warningCount: 0,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
    }

    /// Segment-aligned chapters inside the 300s seed transcript.
    private static func chapters() -> [EpisodeTranscriptAnalysisChapter] {
        let entries: [(title: String, startSegmentID: Int, endSegmentID: Int, startTime: TimeInterval, endTime: TimeInterval)] = [
            ("Opening night on the mountain", 0, 8, 0, 58),
            ("What first light actually tests", 9, 12, 58, 90),
            ("The streak in the corner", 13, 20, 90, 158),
            ("Three exposures and a rough orbit", 21, 29, 158, 232),
            ("The pretty picture, and the next ten years", 30, 39, 232, 300)
        ]
        return entries.enumerated().map { index, entry in
            EpisodeTranscriptAnalysisChapter(
                id: index,
                title: entry.title,
                startSegmentID: entry.startSegmentID,
                endSegmentID: entry.endSegmentID,
                startTime: entry.startTime,
                endTime: entry.endTime,
                confidence: 0.92
            )
        }
    }

    private static func summary() -> EpisodeTranscriptAnalysisSummary {
        EpisodeTranscriptAnalysisSummary(
            summary: "Dana Whitlock follows a new survey telescope through its first night: why the team pointed at an ordinary star field instead of a famous galaxy, how a short, dim streak in the first exposure was narrowed down to a slow-moving rock near the orbit of Mars, and how an improvised follow-up plan earned it a provisional designation within two days. The episode closes with what the telescope will do over the next decade: image the whole southern sky every few nights and flag everything that moves or blinks.",
            oneLineDescription: "A new telescope's first image is only a test, and the faint streak in its corner turns out to be an uncatalogued asteroid.",
            claims: []
        )
    }
}
#endif
