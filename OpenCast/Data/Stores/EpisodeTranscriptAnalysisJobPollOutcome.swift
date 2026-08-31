import Foundation

nonisolated enum EpisodeTranscriptAnalysisJobPollOutcome: Decodable, Sendable, Equatable {
    case running(pollAfter: TimeInterval)
    case completed(EpisodeTranscriptAnalysisAPIResponse)

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.jobID) else {
            self = .completed(try EpisodeTranscriptAnalysisAPIResponse(from: decoder))
            return
        }

        _ = try container.decode(String.self, forKey: .jobID)
        let state = try container.decode(String.self, forKey: .state)
        guard state == "running" else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Unknown transcript-analysis job state: \(state)"
            )
        }
        self = .running(
            pollAfter: try container.decodeIfPresent(TimeInterval.self, forKey: .pollAfter) ?? 5
        )
    }

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state
        case pollAfter = "poll_after_seconds"
    }
}
