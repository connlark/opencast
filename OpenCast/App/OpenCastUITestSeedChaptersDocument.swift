import Foundation
import OpenCastTranscription
import SwiftData

/// UI tests: a completed Chapters & Summary result as an earlier build wrote
/// it (the service's model and policy), so a test can check that documents
/// from before on-device analysis still render. Seeded with
/// `OPENCAST_SEED_CHAPTERS_DOCUMENT=1` beside the completed transcript.
enum OpenCastUITestSeedChaptersDocument {
    static let environmentKey = "OPENCAST_SEED_CHAPTERS_DOCUMENT"
    static let chapterTitles = ["Seeded Welcome", "Seeded Sponsor Read"]
    static let oneLineDescription = "A result saved by an earlier version"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

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
        let chapters = zip(chapterTitles, segments).enumerated().map { index, pair in
            EpisodeTranscriptAnalysisChapter(
                id: index,
                title: pair.0,
                startSegmentID: pair.1.id,
                endSegmentID: pair.1.id,
                startTime: pair.1.start,
                endTime: pair.1.end,
                confidence: 0.9
            )
        }
        let document = EpisodeTranscriptAnalysisDocument(
            schemaVersion: EpisodeTranscriptAnalysisContract.schemaVersion,
            episodeID: episodeID,
            podcastID: transcriptDocument.podcastID,
            requestID: "ui-test-earlier-build",
            transcriptFingerprint: fingerprint,
            transcriptUpdatedAt: transcriptDocument.updatedAt,
            transcriptSegmentCount: segments.count,
            transcriptState: .completed,
            model: "gemini-3.5-flash",
            policy: EpisodeTranscriptAnalysisContract.expectedPolicy,
            chapters: chapters,
            summary: EpisodeTranscriptAnalysisSummary(
                summary: "A seeded summary saved by an earlier version of the app.",
                oneLineDescription: oneLineDescription,
                claims: []
            ),
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
}
