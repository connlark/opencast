import Foundation

/// The persisted fields an accepted analysis job needs to be polled to
/// completion in a later process.
struct AnalysisResumeContext: Sendable, Equatable {
    var episodeID: String
    var podcastID: String
    var transcriptFingerprint: String
    var transcriptUpdatedAt: Date
    var transcriptSegmentCount: Int
    var analysisRelativePath: String

    init?(record: some TranscriptDerivedAnalysisRecord) {
        guard !record.transcriptFingerprint.isEmpty,
              let analysisRelativePath = record.analysisRelativePath,
              !analysisRelativePath.isEmpty
        else {
            return nil
        }

        episodeID = record.episodeID
        podcastID = record.podcastID
        transcriptFingerprint = record.transcriptFingerprint
        transcriptUpdatedAt = record.transcriptUpdatedAt
        transcriptSegmentCount = record.transcriptSegmentCount
        self.analysisRelativePath = analysisRelativePath
    }
}
