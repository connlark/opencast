import Foundation

nonisolated struct EpisodeTranscriptAnalysisDocument: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var episodeID: String
    var podcastID: String
    var requestID: String
    var transcriptFingerprint: String
    var transcriptUpdatedAt: Date
    var transcriptSegmentCount: Int
    var transcriptState: EpisodeTranscriptState
    var model: String
    var policy: String
    var chapters: [EpisodeTranscriptAnalysisChapter]
    var summary: EpisodeTranscriptAnalysisSummary?
    var warnings: [String]
    var usage: EpisodeTranscriptAnalysisUsage?
    var createdAt: Date
    var updatedAt: Date

    /// Whether the analysis carries anything the detail surface can render.
    /// A completed-but-empty analysis (no chapters, no summary) must not
    /// count as a presentable result: treating it as current would blank the
    /// surface and suppress Generate permanently.
    var hasPresentableContent: Bool {
        !chapters.isEmpty || summary != nil
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case episodeID
        case podcastID
        case requestID
        case transcriptFingerprint
        case transcriptUpdatedAt
        case transcriptSegmentCount
        case transcriptState
        case model
        case policy
        case chapters
        case summary
        case warnings
        case usage
        case createdAt
        case updatedAt
    }

    init(
        schemaVersion: Int,
        episodeID: String,
        podcastID: String,
        requestID: String,
        transcriptFingerprint: String,
        transcriptUpdatedAt: Date,
        transcriptSegmentCount: Int,
        transcriptState: EpisodeTranscriptState = .completed,
        model: String,
        policy: String,
        chapters: [EpisodeTranscriptAnalysisChapter],
        summary: EpisodeTranscriptAnalysisSummary?,
        warnings: [String],
        usage: EpisodeTranscriptAnalysisUsage?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.requestID = requestID
        self.transcriptFingerprint = transcriptFingerprint
        self.transcriptUpdatedAt = transcriptUpdatedAt
        self.transcriptSegmentCount = transcriptSegmentCount
        self.transcriptState = transcriptState
        self.model = model
        self.policy = policy
        self.chapters = chapters
        self.summary = summary
        self.warnings = warnings
        self.usage = usage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        episodeID = try container.decode(String.self, forKey: .episodeID)
        podcastID = try container.decode(String.self, forKey: .podcastID)
        requestID = try container.decode(String.self, forKey: .requestID)
        transcriptFingerprint = try container.decode(String.self, forKey: .transcriptFingerprint)
        transcriptUpdatedAt = try container.decode(Date.self, forKey: .transcriptUpdatedAt)
        transcriptSegmentCount = try container.decode(Int.self, forKey: .transcriptSegmentCount)
        transcriptState = try container.decodeIfPresent(
            EpisodeTranscriptState.self,
            forKey: .transcriptState
        ) ?? .completed
        model = try container.decode(String.self, forKey: .model)
        policy = try container.decode(String.self, forKey: .policy)
        chapters = try container.decode([EpisodeTranscriptAnalysisChapter].self, forKey: .chapters)
        summary = try container.decodeIfPresent(EpisodeTranscriptAnalysisSummary.self, forKey: .summary)
        warnings = try container.decode([String].self, forKey: .warnings)
        usage = try container.decodeIfPresent(EpisodeTranscriptAnalysisUsage.self, forKey: .usage)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
