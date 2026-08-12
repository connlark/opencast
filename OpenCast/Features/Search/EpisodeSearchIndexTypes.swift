import Foundation

nonisolated struct EpisodeSearchIndexRequest: Sendable {
    let query: String
    let mode: EpisodeSearchMode
    let activePodcastIDs: Set<String>
    let allowedEpisodeIDs: Set<String>?
    let limit: Int

    /// The legacy matcher returned every match, so the default limit must be
    /// effectively unreachable for a real library; it exists as a top-K
    /// safety bound, not a presentation cap. Benchmark callers may pass a
    /// smaller explicit limit.
    static let defaultLimit = 1000

    init(
        query: String,
        mode: EpisodeSearchMode,
        activePodcastIDs: Set<String>,
        allowedEpisodeIDs: Set<String>? = nil,
        limit: Int = EpisodeSearchIndexRequest.defaultLimit
    ) {
        self.query = query
        self.mode = mode
        self.activePodcastIDs = activePodcastIDs
        self.allowedEpisodeIDs = allowedEpisodeIDs
        self.limit = max(1, min(limit, 2 * EpisodeSearchIndexRequest.defaultLimit))
    }
}

nonisolated struct EpisodeSearchTranscriptSegment: Sendable {
    let segmentID: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
}

nonisolated struct EpisodeSearchTranscriptDocument: Sendable {
    let episodeID: String
    let podcastID: String
    let version: String
    let segments: [EpisodeSearchTranscriptSegment]
}

nonisolated struct EpisodeSearchPassageEvidence: Sendable {
    let segmentID: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
}

nonisolated enum EpisodeSearchIndexChannel: String, Codable, Sendable {
    case exact
    case prefix
    case relaxed
    case corrected
    case visibleSubstring = "visible-substring"
    case transcript

    var scorePenalty: Double {
        switch self {
        case .exact:
            0
        case .prefix:
            2.5
        case .relaxed:
            6
        case .corrected:
            8
        case .visibleSubstring:
            2.5
        case .transcript:
            1
        }
    }
}

nonisolated enum EpisodeSearchMatchedField: String, Codable, Hashable, Sendable {
    case title
    case podcastTitle
    case summary
    case showNotes
    case transcript
}

nonisolated struct EpisodeSearchScoreTrace: Codable, Sendable {
    let channel: EpisodeSearchIndexChannel
    let rawBM25: Double
    let exactTitle: Bool
    let titlePhrase: Bool
    let exactPodcastTitle: Bool
    let podcastTitlePhrase: Bool
    let matchedFields: Set<EpisodeSearchMatchedField>
    let recencyBoost: Double
    let finalScore: Double
}

nonisolated struct EpisodeSearchIndexHit: Sendable {
    let episodeID: String
    let titleHighlightTerms: [String]
    let podcastTitleHighlightTerms: [String]
    let snippet: String?
    let snippetHighlightTerms: [String]
    let transcriptPassage: EpisodeSearchPassageEvidence?
    let scoreTrace: EpisodeSearchScoreTrace

    var transcriptStartTime: TimeInterval? {
        transcriptPassage?.startSeconds
    }
}

nonisolated enum EpisodeSearchIndexError: LocalizedError, Sendable {
    case unavailable
    case rebuilding
    case notReady(String)
    case invalidSchema

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The episode search index is unavailable."
        case .rebuilding:
            "The episode search index is rebuilding."
        case .notReady(let state):
            "The episode search index is not ready (\(state))."
        case .invalidSchema:
            "The episode search index schema is invalid."
        }
    }
}
